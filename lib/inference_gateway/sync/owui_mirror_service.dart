import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_message.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/api_service.dart';
import '../../core/services/connectivity_service.dart';
import '../../core/utils/debug_logger.dart';
import '../cache/conversation_message_cache.dart';
import 'owui_mirror_outbox.dart';

/// Pushes locally-completed gateway turns to OWUI so other devices stay in
/// sync. The inference path never waits on this — `markDirty` enqueues, the
/// flush runs in the background, retries on connectivity restore, and is a
/// no-op when there is no API service (signed out / no server).
///
/// We push the FULL authoritative message list per conversation using the
/// existing `ApiService.syncConversationMessages`, so OWUI ends up holding
/// the same tree the device has — no per-turn merge logic needed here.
class OwuiMirrorService {
  OwuiMirrorService(this._ref) : _outbox = OwuiMirrorOutbox();

  final Ref _ref;
  final OwuiMirrorOutbox _outbox;

  Timer? _debounce;
  bool _flushing = false;
  ProviderSubscription<ConnectivityStatus>? _connectivitySub;
  bool _wired = false;

  /// A conversation whose last assistant turn never finished streaming
  /// (e.g. app force-killed mid-stream) stays "isStreaming: true" in the
  /// cache forever. Without a cap, we'd requeue every 1.5s for the lifetime
  /// of the process. Drop it after this long.
  static const Duration _maxPendingAge = Duration(minutes: 30);

  /// Called from the app startup providers — begins watching connectivity
  /// and drains anything left over from a previous session.
  void wire() {
    if (_wired) return;
    _wired = true;
    _connectivitySub = _ref.listen<ConnectivityStatus>(
      connectivityStatusProvider,
      (previous, next) {
        if (previous != ConnectivityStatus.online &&
            next == ConnectivityStatus.online) {
          unawaited(flush());
        }
      },
      fireImmediately: false,
    );
    // Best-effort drain on wire (e.g., app cold start with pending entries).
    // Defer to a microtask: wire() runs inside the owuiMirrorServiceProvider
    // create callback, which itself runs inside gatewayInferenceRouterProvider,
    // which runs inside apiServiceProvider. Calling flush() synchronously here
    // would reenter apiServiceProvider via _ref.read while it's still being
    // built, which Riverpod rejects with ProviderException.
    Future.microtask(flush);
  }

  void dispose() {
    _debounce?.cancel();
    _connectivitySub?.close();
    _connectivitySub = null;
    _wired = false;
  }

  /// True when [conversationId] has a pending push not yet mirrored to OWUI.
  /// Chat-merge logic uses this to decide whether a fresh server snapshot is
  /// authoritative (no pending → trust the server, including deletions) or
  /// staler than local state (pending → keep local).
  bool isPending(String conversationId) {
    if (conversationId.isEmpty) return false;
    return _outbox.hasPending(conversationId);
  }

  /// Mark a conversation dirty. Schedules a debounced flush so consecutive
  /// edits within ~1.5s coalesce into a single OWUI push.
  Future<void> markDirty(String conversationId) async {
    if (conversationId.isEmpty) return;
    if (conversationId.startsWith('local:')) {
      // Local-only chats have no server-side identity yet. Skip until the
      // chat has been promoted to a real OWUI conversation; the existing
      // chat-creation flow does that and the next turn will enqueue.
      return;
    }
    await _outbox.markDirty(conversationId);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      unawaited(flush());
    });
  }

  /// Push every dirty conversation to OWUI. Safe to call repeatedly.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    var requeue = false;
    try {
      final api = _ref.read(apiServiceProvider);
      if (api == null) return;
      final pending = _outbox.pending();
      if (pending.isEmpty) return;

      final cache = _ref.read(conversationMessageCacheProvider);

      final now = DateTime.now();
      for (final entry in pending) {
        // Don't let a stuck conversation churn the loop indefinitely.
        if (now.difference(entry.dirtyAt) > _maxPendingAge) {
          DebugLogger.warning(
            'mirror-dropped-stale',
            scope: 'gateway/mirror',
            data: {
              'conversationId': entry.conversationId,
              'ageMinutes': now.difference(entry.dirtyAt).inMinutes,
              'retries': entry.retries,
            },
          );
          await _outbox.markFlushed(entry.conversationId);
          continue;
        }
        final messages = cache.load(entry.conversationId) ?? const [];
        if (messages.isEmpty) {
          // Cache hasn't populated yet — the user may not have reopened
          // this chat post-restart. Bump retries (drops after maxRetries)
          // and try again next cycle.
          final dropped = await _outbox.recordFailure(
            entry.conversationId,
            'no local messages cached',
          );
          if (!dropped) requeue = true;
          continue;
        }
        // A stuck `isStreaming: true` (app killed mid-stream) would otherwise
        // requeue forever. Bump retries on each cycle so the maxRetries cap
        // breaks the loop instead of burning CPU until _maxPendingAge.
        if (messages.any((m) => m.role == 'assistant' && m.isStreaming)) {
          final dropped = await _outbox.recordFailure(
            entry.conversationId,
            'assistant message still streaming',
          );
          if (!dropped) requeue = true;
          continue;
        }
        try {
          await _push(api, entry.conversationId, messages);
          await _outbox.markFlushed(entry.conversationId);
          DebugLogger.log(
            'mirror-ok',
            scope: 'gateway/mirror',
            data: {
              'conversationId': entry.conversationId,
              'messages': messages.length,
            },
          );
        } catch (error, stackTrace) {
          DebugLogger.error(
            'mirror-failed',
            scope: 'gateway/mirror',
            error: error,
            stackTrace: stackTrace,
            data: {'conversationId': entry.conversationId},
          );
          final dropped =
              await _outbox.recordFailure(entry.conversationId, error);
          if (!dropped) requeue = true;
        }
      }
    } finally {
      _flushing = false;
      if (requeue) _scheduleFlush();
    }
  }

  Future<void> _push(
    ApiService api,
    String conversationId,
    List<ChatMessage> messages,
  ) async {
    String? title;
    String? model;
    final active = _ref.read(activeConversationProvider);
    if (active != null && active.id == conversationId) {
      title = active.title;
    }
    // Pick the most recent assistant model as the conversation's model hint.
    for (final m in messages.reversed) {
      if (m.role == 'assistant' && m.model != null && m.model!.isNotEmpty) {
        model = m.model;
        break;
      }
    }
    // Gateway chats bypass OWUI's server-side `title_generation` task, so
    // a freshly mirrored chat would sit as "New Chat" until renamed. Seed
    // a fast local title from the first user prompt — the ⚡ prefix flags
    // it as gateway-generated so it's distinguishable from OWUI's LLM
    // titles at a glance.
    final seededTitle =
        _seedTitleIfMissing(currentTitle: title, messages: messages);
    final pushTitle = seededTitle ?? title;
    await api.syncConversationMessages(
      conversationId,
      messages,
      title: pushTitle,
      model: model,
    );
    if (seededTitle != null && active != null && active.id == conversationId) {
      _ref
          .read(activeConversationProvider.notifier)
          .set(active.copyWith(title: seededTitle));
      _ref.read(conversationsProvider.notifier).updateConversationFromRemote(
            conversationId,
            (c) => c.copyWith(title: seededTitle, updatedAt: DateTime.now()),
          );
      refreshConversationsCache(_ref);
    }
  }

  static String? _seedTitleIfMissing({
    required String? currentTitle,
    required List<ChatMessage> messages,
  }) {
    final t = currentTitle?.trim() ?? '';
    if (t.isNotEmpty && t != 'New Chat') return null;
    String? firstUserContent;
    for (final m in messages) {
      if (m.role == 'user' && m.content.trim().isNotEmpty) {
        firstUserContent = m.content;
        break;
      }
    }
    if (firstUserContent == null) return null;
    final words = firstUserContent
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .split(' ')
        .take(6)
        .join(' ');
    if (words.isEmpty) return null;
    final clipped = words.length > 48 ? '${words.substring(0, 48)}…' : words;
    return '⚡ $clipped';
  }
}
