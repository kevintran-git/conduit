import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../../core/persistence/hive_boxes.dart';

/// One dirty-conversation record waiting to be pushed to OWUI.
class OwuiMirrorEntry {
  OwuiMirrorEntry({
    required this.conversationId,
    required this.dirtyAt,
    this.retries = 0,
    this.lastError,
    this.nextAttemptAt,
    this.failed = false,
  });

  final String conversationId;
  DateTime dirtyAt;
  int retries;
  String? lastError;

  /// Earliest time this entry should be retried. Set by [OwuiMirrorOutbox.recordFailure]
  /// to back off after a real push error; `null` means "retry as soon as possible".
  DateTime? nextAttemptAt;

  /// True once retries have crossed [OwuiMirrorOutbox.maxRetries]. The entry is
  /// KEPT (never silently dropped) so the user can't lose data, but the UI can
  /// surface it as failed and offer a manual retry.
  bool failed;

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'dirtyAt': dirtyAt.toIso8601String(),
    'retries': retries,
    if (lastError != null) 'lastError': lastError,
    if (nextAttemptAt != null) 'nextAttemptAt': nextAttemptAt!.toIso8601String(),
    if (failed) 'failed': true,
  };

  factory OwuiMirrorEntry.fromJson(Map<String, dynamic> json) {
    return OwuiMirrorEntry(
      conversationId: json['conversationId'] as String,
      dirtyAt:
          DateTime.tryParse(json['dirtyAt']?.toString() ?? '') ?? DateTime.now(),
      retries: (json['retries'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
      nextAttemptAt: DateTime.tryParse(json['nextAttemptAt']?.toString() ?? ''),
      failed: json['failed'] == true,
    );
  }
}

/// Persistent "needs-sync-to-OWUI" set, keyed by conversation ID.
///
/// Lives in the existing Hive `caches` box under the `owui_mirror::` prefix —
/// no schema migration. Each conversation appears at most once; we don't
/// queue per-turn events because we always push the full authoritative
/// snapshot from local state when we flush.
///
/// Entries are never silently dropped: a conversation that keeps failing is
/// marked [OwuiMirrorEntry.failed] and backed off, but stays queued so the
/// "if I can see it, it should eventually reach OWUI" guarantee holds.
class OwuiMirrorOutbox {
  OwuiMirrorOutbox();

  static const String _prefix = 'owui_mirror::';

  /// After this many consecutive failures we flag the entry as [OwuiMirrorEntry.failed]
  /// (so the UI can show it and offer manual retry) and cap the backoff. We do
  /// NOT delete it — losing a turn the user already saw is the bug we're fixing.
  static const int maxRetries = 8;

  /// Exponential backoff base / cap for real push errors.
  static const Duration _backoffBase = Duration(seconds: 5);
  static const Duration _backoffCap = Duration(minutes: 5);

  Box<dynamic>? _box() {
    if (!Hive.isBoxOpen(HiveBoxNames.caches)) return null;
    return Hive.box<dynamic>(HiveBoxNames.caches);
  }

  String _keyFor(String conversationId) => '$_prefix$conversationId';

  Future<void> markDirty(String conversationId) async {
    final box = _box();
    if (box == null) return;
    final key = _keyFor(conversationId);
    final existing = _decode(box.get(key));
    // New content to push: reset failure state so it retries immediately.
    final entry = existing != null
        ? (existing
          ..dirtyAt = DateTime.now()
          ..lastError = null
          ..retries = 0
          ..nextAttemptAt = null
          ..failed = false)
        : OwuiMirrorEntry(
            conversationId: conversationId,
            dirtyAt: DateTime.now(),
          );
    await box.put(key, jsonEncode(entry.toJson()));
  }

  Future<void> markFlushed(String conversationId) async {
    final box = _box();
    if (box == null) return;
    await box.delete(_keyFor(conversationId));
  }

  /// True when [conversationId] has a pending push waiting to land on OWUI.
  /// Used by chat-merge logic to decide whether the server snapshot is
  /// authoritative (no pending push → trust server, including deletions)
  /// or stale relative to local (pending push → keep local).
  bool hasPending(String conversationId) {
    final box = _box();
    if (box == null) return false;
    return box.containsKey(_keyFor(conversationId));
  }

  /// Bump retries, persist the error, and schedule a backoff. The entry is
  /// kept regardless of retry count; once it crosses [maxRetries] it's flagged
  /// [OwuiMirrorEntry.failed] so the UI can surface it.
  Future<void> recordFailure(String conversationId, Object error) async {
    final box = _box();
    if (box == null) return;
    final key = _keyFor(conversationId);
    final entry = _decode(box.get(key));
    if (entry == null) return;
    entry.retries += 1;
    entry.lastError = error.toString();
    entry.failed = entry.retries >= maxRetries;
    entry.nextAttemptAt = DateTime.now().add(_backoffFor(entry.retries));
    await box.put(key, jsonEncode(entry.toJson()));
  }

  /// Clear backoff / failed state on every entry so the next flush retries them
  /// all immediately. Used by the manual "retry now" action.
  Future<void> resetBackoff() async {
    final box = _box();
    if (box == null) return;
    for (final key in box.keys.toList()) {
      if (key is! String || !key.startsWith(_prefix)) continue;
      final entry = _decode(box.get(key));
      if (entry == null) continue;
      entry.nextAttemptAt = null;
      entry.failed = false;
      await box.put(key, jsonEncode(entry.toJson()));
    }
  }

  Duration _backoffFor(int retries) {
    // 5s, 10s, 20s, ... capped at 5min.
    final shift = (retries - 1).clamp(0, 30);
    final millis = _backoffBase.inMilliseconds * (1 << shift);
    if (millis >= _backoffCap.inMilliseconds || millis <= 0) return _backoffCap;
    return Duration(milliseconds: millis);
  }

  List<OwuiMirrorEntry> pending() {
    final box = _box();
    if (box == null) return const [];
    final entries = <OwuiMirrorEntry>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith(_prefix)) continue;
      final entry = _decode(box.get(key));
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  /// Total conversations queued for OWUI (synced-pending + failed).
  int pendingCount() => pending().length;

  /// Conversations that have crossed [maxRetries] and are flagged failed.
  int failedCount() => pending().where((e) => e.failed).length;

  OwuiMirrorEntry? _decode(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return OwuiMirrorEntry.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
