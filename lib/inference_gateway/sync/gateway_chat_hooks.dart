import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/conversation.dart';
import '../../core/providers/app_providers.dart'
    show activeConversationProvider, isTemporaryChat;
import '../cache/conversation_message_cache.dart';
import '../config/gateway_providers.dart';
import 'owui_mirror_providers.dart';

/// Hook points called from `ChatMessagesNotifier` to keep the gateway's
/// view of conversation state coherent. Lives under `lib/inference_gateway/`
/// so the only edits required in `chat_providers.dart` are 1-line calls.
///
/// If upstream Conduit ever adopts equivalent local-first behavior, the
/// integration sites are easy to spot and remove (search `gateway`-prefixed
/// helpers in chat_providers).

/// Returns the messages to show when the user switches to [conv], or
/// `null` to let the caller fall back to its default (`conv.messages`).
///
/// When the gateway has a still-pending mirror push for this conversation,
/// prefer the local cache so the just-completed turn doesn't briefly
/// disappear. Otherwise: cache the server-backed list opportunistically
/// for instant future opens, and let the caller use them.
List<ChatMessage>? gatewaySeedMessagesForConversation(
  Ref ref,
  Conversation conv,
) {
  final cache = ref.read(conversationMessageCacheProvider);
  final cached = cache.load(conv.id);
  final initial = conv.messages;

  if (initial.isEmpty) {
    return (cached != null && cached.isNotEmpty) ? cached : null;
  }
  if (cached != null &&
      cached.length > initial.length &&
      _localCacheExtendsServer(cached, initial) &&
      ref.read(owuiMirrorServiceProvider).isPending(conv.id)) {
    return cached;
  }
  unawaited(cache.save(conv.id, initial));
  return null;
}

/// True when the server snapshot looks like a stale prefix of local state
/// AND the gateway mirror still has a pending push for this conversation.
/// In that case the caller should keep local state instead of adopting
/// the server view.
bool gatewayShouldRejectServerAdoption(
  Ref ref,
  List<ChatMessage> serverMessages,
  List<ChatMessage> localState,
) {
  if (serverMessages.length >= localState.length) return false;
  if (!_serverIsPrefixOfLocal(serverMessages, localState)) return false;
  final activeId = ref.read(activeConversationProvider)?.id;
  if (activeId == null || activeId.isEmpty) return false;
  return ref.read(owuiMirrorServiceProvider).isPending(activeId);
}

/// Persists [messages] under [conversationId] in the gateway cache so the
/// mirror service can push them to OWUI and so the next open is instant.
/// No-ops for temporary chats, unknown ids, or when chat gateway is off
/// (nothing to push, no reason to fill the cache).
void gatewayPersistMessages(
  Ref ref,
  String? conversationId,
  List<ChatMessage> messages,
) {
  if (conversationId == null || conversationId.isEmpty) return;
  if (isTemporaryChat(conversationId)) return;
  if (!ref.read(gatewayChatActiveProvider)) return;
  unawaited(
    ref.read(conversationMessageCacheProvider).save(conversationId, messages),
  );
}

/// Returns a user-facing message for gateway-originated exceptions, or
/// `null` to let the caller's default error rendering handle it.
String? gatewayErrorMessage(Object error) {
  final msg = error.toString();
  return msg.startsWith('[GATEWAY ') ? msg : null;
}

bool _serverIsPrefixOfLocal(
  List<ChatMessage> serverMessages,
  List<ChatMessage> localState,
) {
  if (serverMessages.length > localState.length) return false;
  for (var i = 0; i < serverMessages.length; i += 1) {
    if (serverMessages[i].id != localState[i].id) return false;
  }
  return true;
}

bool _localCacheExtendsServer(
  List<ChatMessage> cached,
  List<ChatMessage> server,
) {
  if (cached.length <= server.length) return false;
  for (var i = 0; i < server.length; i += 1) {
    if (cached[i].id != server[i].id) return false;
  }
  return true;
}
