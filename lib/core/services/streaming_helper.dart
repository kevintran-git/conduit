import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/socket_event.dart';
import '../../core/services/persistent_streaming_service.dart';
import '../../core/services/socket_service.dart';
import '../../core/utils/inactivity_watchdog.dart';
import '../../core/utils/tool_calls_parser.dart';
import 'navigation_service.dart';
import 'conversation_delta_listener.dart';
import '../../shared/widgets/themed_dialogs.dart';
import '../../shared/theme/theme_extensions.dart';
import '../utils/debug_logger.dart';
import '../utils/openwebui_source_parser.dart';
import 'streaming_response_controller.dart';
import 'api_service.dart';
import 'worker_manager.dart';
import 'platform_service.dart';

// Keep local verbosity toggle for socket logs
const bool kSocketVerboseLogging = false;

// Pre-compiled regex patterns for image extraction (performance optimization)
final _base64ImagePattern = RegExp(
  r'data:image/[^;\s]+;base64,[A-Za-z0-9+/]+=*',
);
final _urlImagePattern = RegExp(
  r'https?://[^\s<>\"]+\.(jpg|jpeg|png|gif|webp)',
  caseSensitive: false,
);
final _jsonImagePattern = RegExp(
  r'\{[^}]*"url"[^}]*:[^}]*"(data:image/[^"]+|https?://[^"]+\.(jpg|jpeg|png|gif|webp))"[^}]*\}',
  caseSensitive: false,
);
final _jsonUrlExtractPattern = RegExp(r'"url"[^:]*:[^"]*"([^"]+)"');
final _partialResultsPattern = RegExp(
  r'(result|files)="([^"]*(?:data:image/[^"]*|https?://[^"]*\.(jpg|jpeg|png|gif|webp))[^"]*)"',
  caseSensitive: false,
);
final _imageFilePattern = RegExp(
  r'https?://[^\s]+\.(jpg|jpeg|png|gif|webp)$',
  caseSensitive: false,
);

List<Map<String, dynamic>> _collectImageReferencesWorker(String content) {
  final collected = <Map<String, dynamic>>[];
  if (content.isEmpty) {
    return collected;
  }

  if (content.contains('<details') && content.contains('</details>')) {
    final parsed = ToolCallsParser.parse(content);
    if (parsed != null) {
      for (final entry in parsed.toolCalls) {
        if (entry.files != null && entry.files!.isNotEmpty) {
          collected.addAll(_extractFilesFromResult(entry.files));
        }
        if (entry.result != null) {
          collected.addAll(_extractFilesFromResult(entry.result));
        }
      }
    }
  }

  if (collected.isNotEmpty) {
    return collected;
  }

  final base64Matches = _base64ImagePattern.allMatches(content);
  for (final match in base64Matches) {
    final url = match.group(0);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final urlMatches = _urlImagePattern.allMatches(content);
  for (final match in urlMatches) {
    final url = match.group(0);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final jsonMatches = _jsonImagePattern.allMatches(content);
  for (final match in jsonMatches) {
    final url = _jsonUrlExtractPattern
        .firstMatch(match.group(0) ?? '')
        ?.group(1);
    if (url != null && url.isNotEmpty) {
      collected.add({'type': 'image', 'url': url});
    }
  }

  final partialMatches = _partialResultsPattern.allMatches(content);
  for (final match in partialMatches) {
    final attrValue = match.group(2);
    if (attrValue == null) continue;
    try {
      final decoded = json.decode(attrValue);
      collected.addAll(_extractFilesFromResult(decoded));
    } catch (_) {
      if (attrValue.startsWith('data:image/') ||
          _imageFilePattern.hasMatch(attrValue)) {
        collected.add({'type': 'image', 'url': attrValue});
      }
    }
  }

  return collected;
}

class ActiveSocketStream {
  ActiveSocketStream({
    required this.controller,
    required this.socketSubscriptions,
    required this.disposeWatchdog,
  });

  final StreamingResponseController controller;
  final List<VoidCallback> socketSubscriptions;
  final VoidCallback disposeWatchdog;
}

/// Unified streaming helper for chat send/regenerate flows.
///
/// This attaches WebSocket event handlers and manages background search/image-gen
/// UI updates. It operates via callbacks to avoid tight coupling with provider files
/// for easier reuse and testing.
ActiveSocketStream attachUnifiedChunkedStreaming({
  required Stream<String> stream,
  required bool webSearchEnabled,
  required String assistantMessageId,
  required String modelId,
  required Map<String, dynamic> modelItem,
  required String? sessionId,
  required String? activeConversationId,
  required ApiService api,
  required SocketService? socketService,
  required WorkerManager workerManager,
  bool hapticFeedbackEnabled = true,
  String chatStreamingMode = 'hybrid', // 'hybrid', 'ws', or 'sse'
  RegisterConversationDeltaListener? registerDeltaListener,
  // Message update callbacks
  required void Function(String) appendToLastMessage,
  required void Function(String) replaceLastMessageContent,
  required void Function(ChatMessage Function(ChatMessage))
  updateLastMessageWith,
  required void Function(String messageId, ChatStatusUpdate update)
  appendStatusUpdate,
  required void Function(String messageId, List<String> followUps) setFollowUps,
  required void Function(String messageId, ChatCodeExecution execution)
  upsertCodeExecution,
  required void Function(String messageId, ChatSourceReference reference)
  appendSourceReference,
  required void Function(
    String messageId,
    ChatMessage Function(ChatMessage current),
  )
  updateMessageById,
  void Function(String newTitle)? onChatTitleUpdated,
  void Function()? onChatTagsUpdated,
  required void Function() finishStreaming,
  required List<ChatMessage> Function() getMessages,
}) {
  // Persistable controller to survive brief app suspensions
  final persistentController = StreamController<String>.broadcast();
  final persistentService = PersistentStreamingService();

  // Log streaming mode for debugging (clear, one-time log)
  final sseActive = chatStreamingMode != 'ws';
  final wsActive = chatStreamingMode != 'sse';
  DebugLogger.log(
    '🔌 Streaming mode: $chatStreamingMode | SSE: ${sseActive ? "✅" : "❌"} | WebSocket: ${wsActive ? "✅" : "❌"}',
    scope: 'streaming/start',
  );

  // Track if stream has received any data
  bool hasReceivedData = false;

  // Track last haptic feedback time to avoid over-triggering
  DateTime? lastHapticTime;
  const hapticThrottleDuration = Duration(milliseconds: 200);
  int _hapticTriggerCount = 0;
  
  // Track chunks for summary logging (reduce verbosity)
  int _chunkCount = 0;
  int _totalCharsReceived = 0;

  // Helper to trigger haptic feedback with throttling
  void triggerHapticFeedback() {
    if (!hapticFeedbackEnabled) {
      DebugLogger.log(
        'Haptic feedback disabled by user',
        scope: 'streaming/haptic',
      );
      return;
    }

    final now = DateTime.now();
    if (lastHapticTime == null ||
        now.difference(lastHapticTime!) > hapticThrottleDuration) {
      lastHapticTime = now;
      _hapticTriggerCount++;
      
      DebugLogger.log(
        'Triggering haptic feedback (#$_hapticTriggerCount)',
        scope: 'streaming/haptic',
      );
      
      try {
        PlatformService.hapticFeedback(type: HapticType.selection);
      } catch (e) {
        DebugLogger.error(
          'haptic-feedback-failed',
          scope: 'streaming/haptic',
          error: e,
        );
      }
    }
  }

  // Create subscription first so we can reference it in onDone
  late final String streamId;
  
  // Use appropriate stream based on mode
  final Stream<String> effectiveStream = chatStreamingMode == 'ws' 
      ? Stream<String>.empty() // No SSE in WebSocket-only mode
      : stream;
  
  final subscription = effectiveStream.listen(
    (data) {
      hasReceivedData = true;
      persistentController.add(data);
    },
    onDone: () async {
      DebugLogger.stream(
        'Source stream onDone fired, hasReceivedData=$hasReceivedData',
      );

      // If stream closes immediately without data, it's likely due to connection drop
      if (!hasReceivedData) {
        DebugLogger.stream(
          'Stream closed without data - checking if backend completed',
        );
        
        // Check if app is backgrounding
        await Future.delayed(const Duration(milliseconds: 300));
        if (persistentService.isInBackground) {
          DebugLogger.stream('App in background - saving state for recovery');
          finishStreaming();
          return;
        }
        
        // In foreground: wait for backend to have a chance to complete
        // LLM responses typically take 5-30+ seconds, so give it time
        await Future.delayed(const Duration(seconds: 3));
        
        // Check if content already arrived via another channel (WebSocket, recovery)
        final currentMsgs = getMessages();
        if (currentMsgs.isNotEmpty && 
            currentMsgs.last.role == 'assistant' &&
            currentMsgs.last.content.trim().isNotEmpty) {
          DebugLogger.stream('Content already present - no need to fetch');
          finishStreaming();
          persistentController.close();
          return;
        }
        
        // Use microtask since refreshConversationSnapshot is defined later
        Future.microtask(() async {
          try {
            final chatId = activeConversationId;
            if (chatId != null && chatId.isNotEmpty) {
              final conversation = await api.getConversation(chatId);
              
              // Update title if available
              if (conversation.title.isNotEmpty && conversation.title != 'New Chat') {
                onChatTitleUpdated?.call(conversation.title);
              }
              
              // Find the assistant message and update it
              if (conversation.messages.isNotEmpty) {
                ChatMessage? foundAssistant;
                for (final message in conversation.messages.reversed) {
                  if (message.role == 'assistant' && message.id == assistantMessageId) {
                    foundAssistant = message;
                    break;
                  }
                }
                
                final assistant = foundAssistant;
                if (assistant != null && assistant.content.trim().isNotEmpty) {
                  DebugLogger.stream('Backend had completed - recovered content');
                  replaceLastMessageContent(assistant.content);
                  triggerHapticFeedback();
                  setFollowUps(assistant.id, assistant.followUps);
                  updateMessageById(assistant.id, (ChatMessage current) {
                    return current.copyWith(
                      followUps: List<String>.from(assistant.followUps),
                      statusHistory: assistant.statusHistory,
                      sources: assistant.sources,
                      metadata: {...?current.metadata, ...?assistant.metadata},
                      usage: assistant.usage,
                    );
                  });
                  finishStreaming();
                  persistentController.close();
                } else {
                  // No content yet - keep stream registered for retry
                  DebugLogger.stream('No content yet - will retry via recovery');
                }
              }
            }
          } catch (e) {
            DebugLogger.error('recovery-fetch-failed', scope: 'streaming/helper', error: e);
          }
        });
        return;
      }

      // For streams with data, delay to allow background detection
      await Future.delayed(const Duration(milliseconds: 500));

      final isInBg = persistentService.isInBackground;
      DebugLogger.stream(
        'Stream onDone check: streamId=$streamId, isInBackground=$isInBg',
      );

      // Check if we're in background before closing
      if (!isInBg) {
        DebugLogger.stream(
          'Closing stream controller for $streamId (foreground completion)',
        );
        persistentController.close();
      } else {
        DebugLogger.stream(
          'Source stream completed in background for $streamId - keeping open for recovery',
        );
        // Finish streaming to save the content we have
        finishStreaming();
      }
    },
    onError: persistentController.addError,
  );

  streamId = persistentService.registerStream(
    subscription: subscription,
    controller: persistentController,
    recoveryCallback: () async {
      DebugLogger.log(
        'Stream interrupted - checking if backend completed',
        scope: 'streaming/helper',
      );
      
      // Wait a bit before fetching - backend might still be processing
      // This is called by PersistentStreamingService which already does exponential backoff,
      // but add a small delay to avoid fetching too eagerly
      await Future.delayed(const Duration(seconds: 2));
      
      // Check if content already arrived via another channel
      final currentMsgs = getMessages();
      if (currentMsgs.isNotEmpty && 
          currentMsgs.last.role == 'assistant' &&
          currentMsgs.last.content.trim().isNotEmpty) {
        DebugLogger.log('Content already present - skipping recovery fetch', scope: 'streaming/helper');
        finishStreaming();
        return;
      }
      
      // Simple recovery: fetch conversation and update message (like a manual reload)
      try {
        final chatId = activeConversationId;
        if (chatId != null && chatId.isNotEmpty) {
          final conversation = await api.getConversation(chatId);
          
          if (conversation.title.isNotEmpty && conversation.title != 'New Chat') {
            onChatTitleUpdated?.call(conversation.title);
          }
          
          if (conversation.messages.isNotEmpty) {
            ChatMessage? foundAssistant;
            for (final message in conversation.messages.reversed) {
              if (message.role == 'assistant' && message.id == assistantMessageId) {
                foundAssistant = message;
                break;
              }
            }
            
            final assistant = foundAssistant;
            if (assistant != null) {
              if (assistant.content.trim().isNotEmpty) {
                replaceLastMessageContent(assistant.content);
                triggerHapticFeedback();
              }
              setFollowUps(assistant.id, assistant.followUps);
              updateMessageById(assistant.id, (ChatMessage current) {
                return current.copyWith(
                  followUps: List<String>.from(assistant.followUps),
                  statusHistory: assistant.statusHistory,
                  sources: assistant.sources,
                  metadata: {...?current.metadata, ...?assistant.metadata},
                  usage: assistant.usage,
                );
              });
            }
          }
        }
      } catch (e) {
        DebugLogger.error('stream-recovery-failed', scope: 'streaming/helper', error: e);
      }
      finishStreaming();
    },
    metadata: {
      'conversationId': activeConversationId,
      'messageId': assistantMessageId,
      'modelId': modelId,
      if (sessionId != null) 'sessionId': sessionId,
    },
  );
  api.registerPersistentStreamForMessage(assistantMessageId, streamId);

  InactivityWatchdog? socketWatchdog;
  final socketSubscriptions = <VoidCallback>[];
  final hasSocketSignals =
      socketService != null || registerDeltaListener != null;
  if (hasSocketSignals) {
    // Increase timeout to match OpenWebUI's more generous timeouts for long responses
    socketWatchdog = InactivityWatchdog(
      window: const Duration(minutes: 15), // Increased from 5 to 15 minutes
      onTimeout: () {
        DebugLogger.log(
          'Socket watchdog timeout - finishing streaming gracefully',
          scope: 'streaming/helper',
        );
        try {
          for (final dispose in socketSubscriptions) {
            try {
              dispose();
            } catch (_) {}
          }
          socketSubscriptions.clear();
        } catch (_) {}
        try {
          final msgs = getMessages();
          if (msgs.isNotEmpty &&
              msgs.last.role == 'assistant' &&
              msgs.last.isStreaming) {
            finishStreaming();
          }
        } catch (_) {}
        socketWatchdog?.stop();
      },
    )..start();
  }

  Timer? imageCollectionDebounce;
  String? pendingImageContent;
  String? pendingImageMessageId;
  String? pendingImageSignature;
  String? lastProcessedImageSignature;
  int imageCollectionRequestId = 0;

  void disposeSocketSubscriptions() {
    if (socketSubscriptions.isEmpty) {
      return;
    }
    for (final dispose in socketSubscriptions) {
      try {
        dispose();
      } catch (_) {}
    }
    socketSubscriptions.clear();
    imageCollectionDebounce?.cancel();
    imageCollectionDebounce = null;
    pendingImageContent = null;
    pendingImageMessageId = null;
    pendingImageSignature = null;
    lastProcessedImageSignature = null;
    imageCollectionRequestId = 0;
    socketWatchdog?.stop();
  }

  bool isSearching = false;

  void runPendingImageCollection() {
    imageCollectionDebounce?.cancel();
    imageCollectionDebounce = null;

    final content = pendingImageContent;
    final targetMessageId = pendingImageMessageId;
    final signature = pendingImageSignature;
    if (content == null || targetMessageId == null || signature == null) {
      return;
    }

    pendingImageContent = null;
    pendingImageMessageId = null;
    pendingImageSignature = null;

    final requestId = ++imageCollectionRequestId;
    unawaited(
      workerManager
          .schedule<String, List<Map<String, dynamic>>>(
            _collectImageReferencesWorker,
            content,
            debugLabel: 'stream_collect_images',
          )
          .then((collected) {
            if (requestId != imageCollectionRequestId) {
              return;
            }

            final currentMessages = getMessages();
            if (currentMessages.isEmpty) {
              return;
            }
            final last = currentMessages.last;
            if (last.id != targetMessageId || last.role != 'assistant') {
              return;
            }

            lastProcessedImageSignature = signature;

            if (collected.isEmpty) {
              return;
            }

            final existing = last.files ?? <Map<String, dynamic>>[];
            final seen = <String>{
              for (final f in existing)
                if (f['url'] is String) (f['url'] as String) else '',
            }..removeWhere((e) => e.isEmpty);

            final merged = <Map<String, dynamic>>[...existing];
            for (final f in collected) {
              final url = f['url'] as String?;
              if (url != null && url.isNotEmpty && !seen.contains(url)) {
                merged.add({'type': 'image', 'url': url});
                seen.add(url);
              }
            }

            if (merged.length != existing.length) {
              updateLastMessageWith((m) => m.copyWith(files: merged));
            }
          })
          .catchError((_) {}),
    );
  }

  void updateImagesFromCurrentContent() {
    try {
      final msgs = getMessages();
      if (msgs.isEmpty || msgs.last.role != 'assistant') return;
      final last = msgs.last;
      final content = last.content;
      if (content.isEmpty) return;

      final targetMessageId = last.id;
      final signature =
          '$targetMessageId:${content.hashCode}:${content.length}';

      if (signature == lastProcessedImageSignature &&
          pendingImageSignature == null) {
        return;
      }
      if (signature == pendingImageSignature) {
        return;
      }

      pendingImageMessageId = targetMessageId;
      pendingImageContent = content;
      pendingImageSignature = signature;

      final shouldDelay = last.isStreaming;

      imageCollectionDebounce?.cancel();
      if (shouldDelay) {
        imageCollectionDebounce = Timer(
          const Duration(milliseconds: 200),
          runPendingImageCollection,
        );
      } else {
        runPendingImageCollection();
      }
    } catch (_) {}
  }

  bool refreshingSnapshot = false;
  Future<void> refreshConversationSnapshot() async {
    if (refreshingSnapshot) return;
    final chatId = activeConversationId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    refreshingSnapshot = true;
    try {
      final conversation = await api.getConversation(chatId);

      if (conversation.title.isNotEmpty && conversation.title != 'New Chat') {
        onChatTitleUpdated?.call(conversation.title);
      }

      if (conversation.messages.isEmpty) {
        return;
      }

      ChatMessage? foundAssistant;
      for (final message in conversation.messages.reversed) {
        if (message.role == 'assistant') {
          foundAssistant = message;
          break;
        }
      }

      final assistant = foundAssistant;
      if (assistant == null) {
        return;
      }

      setFollowUps(assistant.id, assistant.followUps);
      updateMessageById(assistant.id, (current) {
        return current.copyWith(
          followUps: List<String>.from(assistant.followUps),
          statusHistory: assistant.statusHistory,
          sources: assistant.sources,
          metadata: {...?current.metadata, ...?assistant.metadata},
          usage: assistant.usage,
        );
      });
    } catch (_) {
      // Best-effort refresh; ignore failures.
    } finally {
      refreshingSnapshot = false;
    }
  }

  void channelLineHandlerFactory(String channel) {
    void handler(dynamic line) {
      try {
        if (line is String) {
          final s = line.trim();
          socketWatchdog?.ping();
          // Enhanced completion detection matching OpenWebUI patterns
          if (s == '[DONE]' || s == 'DONE' || s == 'data: [DONE]') {
            try {
              socketService?.offEvent(channel);
            } catch (_) {}
            try {
              // Fire and forget
              // ignore: unawaited_futures
              api.sendChatCompleted(
                chatId: activeConversationId ?? '',
                messageId: assistantMessageId,
                messages: const [],
                model: modelId,
                modelItem: modelItem,
                sessionId: sessionId,
              );
            } catch (_) {}
            finishStreaming();
            socketWatchdog?.stop();
            return;
          }
          if (s.startsWith('data:')) {
            final dataStr = s.substring(5).trim();
            if (dataStr == '[DONE]') {
              try {
                socketService?.offEvent(channel);
              } catch (_) {}
              try {
                // ignore: unawaited_futures
                api.sendChatCompleted(
                  chatId: activeConversationId ?? '',
                  messageId: assistantMessageId,
                  messages: const [],
                  model: modelId,
                  modelItem: modelItem,
                  sessionId: sessionId,
                );
              } catch (_) {}
              finishStreaming();
              socketWatchdog?.stop();
              return;
            }
            try {
              final Map<String, dynamic> j = jsonDecode(dataStr);
              final choices = j['choices'];
              if (choices is List && choices.isNotEmpty) {
                final choice = choices.first;
                final delta = choice is Map ? choice['delta'] : null;
                if (delta is Map) {
                  if (delta.containsKey('tool_calls')) {
                    final tc = delta['tool_calls'];
                    if (tc is List) {
                      for (final call in tc) {
                        if (call is Map<String, dynamic>) {
                          final fn = call['function'];
                          final name = (fn is Map && fn['name'] is String)
                              ? fn['name'] as String
                              : null;
                          if (name is String && name.isNotEmpty) {
                            final msgs = getMessages();
                            // Quick string check before expensive regex
                            final exists =
                                (msgs.isNotEmpty) &&
                                msgs.last.content.contains('name="$name"');
                            if (!exists) {
                              final status =
                                  '\n<details type="tool_calls" done="false" name="$name"><summary>Executing...</summary>\n</details>\n';
                              appendToLastMessage(status);
                            }
                          }
                        }
                      }
                    }
                  }
                  final content = delta['content']?.toString() ?? '';
                  if (content.isNotEmpty) {
                    appendToLastMessage(content);
                    triggerHapticFeedback();
                    updateImagesFromCurrentContent();
                  }
                }
              }
            } catch (_) {
              if (s.isNotEmpty) {
                appendToLastMessage(s);
                triggerHapticFeedback();
                updateImagesFromCurrentContent();
              }
            }
          } else {
            if (s.isNotEmpty) {
              appendToLastMessage(s);
              triggerHapticFeedback();
              updateImagesFromCurrentContent();
            }
          }
        } else if (line is Map) {
          socketWatchdog?.ping();
          if (line['done'] == true) {
            try {
              socketService?.offEvent(channel);
            } catch (_) {}
            finishStreaming();
            socketWatchdog?.stop();
            return;
          }
        }
      } catch (_) {}
    }

    try {
      socketService?.onEvent(channel, handler);
    } catch (_) {}
    socketWatchdog?.ping();
    // Increased timeout to match our more generous streaming timeouts
    // OpenWebUI doesn't have such aggressive channel timeouts
    Future.delayed(const Duration(minutes: 12), () {
      try {
        socketService?.offEvent(channel);
      } catch (_) {}
      socketWatchdog?.stop();
    });
  }

  void chatHandler(
    Map<String, dynamic> ev,
    void Function(dynamic response)? ack,
  ) {
    try {
      final data = ev['data'];
      if (data == null) return;
      final type = data['type'];

      // Basic logging to see if chat events are being received
      if (type != null &&
          (type.toString().contains('follow') ||
              type == 'chat:message:follow_ups')) {
        DebugLogger.log(
          'Chat event received: $type',
          scope: 'streaming/helper',
        );
      }
      final payload = data['data'];
      final messageId = ev['message_id']?.toString();
      socketWatchdog?.ping();

      if (kSocketVerboseLogging && payload is Map) {
        DebugLogger.log(
          'socket delta type=$type session=$sessionId message=$messageId keys=${payload.keys.toList()}',
          scope: 'socket/chat',
        );
      }

      if (type == 'chat:completion' && payload != null) {
        if (payload is Map<String, dynamic>) {
          final rawSources = payload['sources'] ?? payload['citations'];
          final normalizedSources = _normalizeSourcesPayload(rawSources);
          if (normalizedSources != null && normalizedSources.isNotEmpty) {
            final parsedSources = parseOpenWebUISourceList(normalizedSources);
            if (parsedSources.isNotEmpty) {
              final targetId = _resolveTargetMessageId(messageId, getMessages);
              if (targetId != null) {
                for (final source in parsedSources) {
                  appendSourceReference(targetId, source);
                }
              }
            }
          }
          if (payload.containsKey('tool_calls')) {
            final tc = payload['tool_calls'];
            if (tc is List) {
              for (final call in tc) {
                if (call is Map<String, dynamic>) {
                  final fn = call['function'];
                  final name = (fn is Map && fn['name'] is String)
                      ? fn['name'] as String
                      : null;
                  if (name is String && name.isNotEmpty) {
                    final msgs = getMessages();
                    // Quick string check before expensive regex
                    final exists =
                        (msgs.isNotEmpty) &&
                        msgs.last.content.contains('name="$name"');
                    if (!exists) {
                      final status =
                          '\n<details type="tool_calls" done="false" name="$name"><summary>Executing...</summary>\n</details>\n';
                      appendToLastMessage(status);
                    }
                  }
                }
              }
            }
          }
          if (payload.containsKey('choices')) {
            final choices = payload['choices'];
            if (choices is List && choices.isNotEmpty) {
              final choice = choices.first;
              final delta = choice is Map ? choice['delta'] : null;
              if (delta is Map) {
                if (delta.containsKey('tool_calls')) {
                  final tc = delta['tool_calls'];
                  if (tc is List) {
                    for (final call in tc) {
                      if (call is Map<String, dynamic>) {
                        final fn = call['function'];
                        final name = (fn is Map && fn['name'] is String)
                            ? fn['name'] as String
                            : null;
                        if (name is String && name.isNotEmpty) {
                          final msgs = getMessages();
                          // Quick string check before expensive regex
                          final exists =
                              (msgs.isNotEmpty) &&
                              msgs.last.content.contains('name="$name"');
                          if (!exists) {
                            final status =
                                '\n<details type="tool_calls" done="false" name="$name"><summary>Executing...</summary>\n</details>\n';
                            appendToLastMessage(status);
                          }
                        }
                      }
                    }
                  }
                }
                final content = delta['content']?.toString() ?? '';
                if (content.isNotEmpty) {
                  appendToLastMessage(content);
                  updateImagesFromCurrentContent();
                }
              }
            }
          }
          if (payload.containsKey('content')) {
            final raw = payload['content']?.toString() ?? '';
            if (raw.isNotEmpty) {
              replaceLastMessageContent(raw);
              triggerHapticFeedback();
              updateImagesFromCurrentContent();
            }
          }
          if (payload['done'] == true) {
            try {
              // ignore: unawaited_futures
              api.sendChatCompleted(
                chatId: activeConversationId ?? '',
                messageId: assistantMessageId,
                messages: const [],
                model: modelId,
                modelItem: modelItem,
                sessionId: sessionId,
              );
            } catch (_) {}

            Future.microtask(refreshConversationSnapshot);

            final msgs = getMessages();
            if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
              final lastContent = msgs.last.content.trim();
              if (lastContent.isEmpty) {
                Future.microtask(() async {
                  try {
                    final chatId = activeConversationId;
                    if (chatId != null && chatId.isNotEmpty) {
                      final resp = await api.dio.get('/api/v1/chats/$chatId');
                      final data = resp.data as Map<String, dynamic>?;
                      String content = '';
                      final chatObj = data?['chat'] as Map<String, dynamic>?;
                      if (chatObj != null) {
                        final list = chatObj['messages'];
                        if (list is List) {
                          final target = list.firstWhere(
                            (m) =>
                                (m is Map &&
                                (m['id']?.toString() == assistantMessageId)),
                            orElse: () => null,
                          );
                          if (target != null) {
                            final rawContent = (target as Map)['content'];
                            if (rawContent is String) {
                              content = rawContent;
                            } else if (rawContent is List) {
                              final textItem = rawContent.firstWhere(
                                (i) => i is Map && i['type'] == 'text',
                                orElse: () => null,
                              );
                              if (textItem != null) {
                                content = textItem['text']?.toString() ?? '';
                              }
                            }
                          }
                        }
                        if (content.isEmpty) {
                          final history = chatObj['history'];
                          if (history is Map && history['messages'] is Map) {
                            final Map<String, dynamic> messagesMap =
                                (history['messages'] as Map)
                                    .cast<String, dynamic>();
                            final msg = messagesMap[assistantMessageId];
                            if (msg is Map) {
                              final rawContent = msg['content'];
                              if (rawContent is String) {
                                content = rawContent;
                              } else if (rawContent is List) {
                                final textItem = rawContent.firstWhere(
                                  (i) => i is Map && i['type'] == 'text',
                                  orElse: () => null,
                                );
                                if (textItem != null) {
                                  content = textItem['text']?.toString() ?? '';
                                }
                              }
                            }
                          }
                        }
                      }
                      if (content.isNotEmpty) {
                        replaceLastMessageContent(content);
                        triggerHapticFeedback();
                      }
                    }
                  } catch (_) {
                  } finally {
                    finishStreaming();
                  }
                });
                return;
              }
            }
            finishStreaming();
            socketWatchdog?.stop();
          }
        }
      } else if (type == 'status' && payload != null) {
        final statusMap = _asStringMap(payload);
        final targetId = _resolveTargetMessageId(messageId, getMessages);
        if (statusMap != null && targetId != null) {
          try {
            final statusUpdate = ChatStatusUpdate.fromJson(statusMap);
            appendStatusUpdate(targetId, statusUpdate);
            updateMessageById(targetId, (current) {
              final metadata = {
                ...?current.metadata,
                'status': statusUpdate.toJson(),
              };
              return current.copyWith(metadata: metadata);
            });
          } catch (_) {}
        }
      } else if (type == 'chat:tasks:cancel') {
        final targetId = _resolveTargetMessageId(messageId, getMessages);
        if (targetId != null) {
          updateMessageById(targetId, (current) {
            final metadata = {...?current.metadata, 'tasksCancelled': true};
            return current.copyWith(metadata: metadata, isStreaming: false);
          });
        }
        disposeSocketSubscriptions();
        finishStreaming();
      } else if (type == 'chat:message:follow_ups' && payload != null) {
        DebugLogger.log('Received follow-ups event', scope: 'streaming/helper');
        final followMap = _asStringMap(payload);
        if (followMap != null) {
          final followUpsRaw =
              followMap['follow_ups'] ?? followMap['followUps'];
          final suggestions = _parseFollowUpsField(followUpsRaw);
          final targetId = _resolveTargetMessageId(messageId, getMessages);
          DebugLogger.log(
            'Follow-ups: ${suggestions.length} suggestions for message $targetId',
            scope: 'streaming/helper',
          );
          if (targetId != null) {
            setFollowUps(targetId, suggestions);
            updateMessageById(targetId, (current) {
              final metadata = {...?current.metadata, 'followUps': suggestions};
              return current.copyWith(metadata: metadata);
            });
            DebugLogger.log(
              'Follow-ups set successfully',
              scope: 'streaming/helper',
            );
          } else {
            DebugLogger.log(
              'Follow-ups: targetId is null',
              scope: 'streaming/helper',
            );
          }
        } else {
          DebugLogger.log(
            'Follow-ups: failed to parse payload',
            scope: 'streaming/helper',
          );
        }
      } else if (type == 'chat:title' && payload != null) {
        final title = payload.toString();
        if (title.isNotEmpty) {
          onChatTitleUpdated?.call(title);
        }
      } else if (type == 'chat:tags') {
        onChatTagsUpdated?.call();
      } else if ((type == 'source' || type == 'citation') && payload != null) {
        final map = _asStringMap(payload);
        if (map != null) {
          if (map['type']?.toString() == 'code_execution') {
            try {
              final exec = ChatCodeExecution.fromJson(map);
              final targetId = _resolveTargetMessageId(messageId, getMessages);
              if (targetId != null) {
                upsertCodeExecution(targetId, exec);
              }
            } catch (_) {}
          } else {
            try {
              final sources = parseOpenWebUISourceList([map]);
              if (sources.isNotEmpty) {
                final targetId = _resolveTargetMessageId(
                  messageId,
                  getMessages,
                );
                if (targetId != null) {
                  for (final source in sources) {
                    appendSourceReference(targetId, source);
                  }
                }
              }
            } catch (_) {}
          }
        }
      } else if (type == 'notification' && payload != null) {
        final map = _asStringMap(payload);
        if (map != null) {
          final notifType = map['type']?.toString() ?? 'info';
          final content = map['content']?.toString() ?? '';
          _showSocketNotification(notifType, content);
        }
      } else if (type == 'confirmation' && payload != null) {
        if (ack != null) {
          final map = _asStringMap(payload);
          if (map != null) {
            () async {
              final confirmed = await _showConfirmationDialog(map);
              try {
                ack(confirmed);
              } catch (_) {}
            }();
          } else {
            ack(false);
          }
        }
      } else if (type == 'execute' && payload != null) {
        if (ack != null) {
          final map = _asStringMap(payload);
          final description = map?['description']?.toString();
          final errorMsg = description?.isNotEmpty == true
              ? description!
              : 'Client-side execute events are not supported.';
          try {
            ack({'error': errorMsg});
          } catch (_) {}
          _showSocketNotification('warning', errorMsg);
        }
      } else if (type == 'input' && payload != null) {
        if (ack != null) {
          final map = _asStringMap(payload);
          if (map != null) {
            () async {
              final response = await _showInputDialog(map);
              try {
                ack(response);
              } catch (_) {}
            }();
          } else {
            ack(null);
          }
        }
      } else if (type == 'chat:message:error' && payload != null) {
        // Server reports an error for the current assistant message
        try {
          dynamic err = payload is Map ? payload['error'] : null;
          String content = '';
          if (err is Map) {
            final c = err['content'];
            if (c is String) {
              content = c;
            } else if (c != null) {
              content = c.toString();
            }
          } else if (err is String) {
            content = err;
          } else if (payload is Map && payload['message'] is String) {
            content = payload['message'];
          }
          if (content.isNotEmpty) {
            // Replace current assistant message with a readable error
            replaceLastMessageContent('⚠️ $content');
          }
        } catch (_) {}
        // Drop search-only status rows so the error feels cleaner
        updateLastMessageWith((message) {
          final filtered = message.statusHistory
              .where((status) => status.action != 'knowledge_search')
              .toList(growable: false);
          if (filtered.length == message.statusHistory.length) {
            return message;
          }
          return message.copyWith(statusHistory: filtered);
        });
        // Ensure UI exits streaming state
        finishStreaming();
        socketWatchdog?.stop();
      } else if ((type == 'chat:message:delta' || type == 'message') &&
          payload != null) {
        // Incremental message content over socket
        final content = payload['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          appendToLastMessage(content);
          triggerHapticFeedback();
          updateImagesFromCurrentContent();
        }
      } else if ((type == 'chat:message' || type == 'replace') &&
          payload != null) {
        // Full message replacement over socket
        final content = payload['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          replaceLastMessageContent(content);
          triggerHapticFeedback();
        }
      } else if ((type == 'chat:message:files') && payload != null) {
        // Alias for files event used by web client
        try {
          final files = _extractFilesFromResult(payload['files'] ?? payload);
          if (files.isNotEmpty) {
            final msgs = getMessages();
            if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
              final existing = msgs.last.files ?? <Map<String, dynamic>>[];
              final seen = <String>{
                for (final f in existing)
                  if (f['url'] is String) (f['url'] as String) else '',
              }..removeWhere((e) => e.isEmpty);
              final merged = <Map<String, dynamic>>[...existing];
              for (final f in files) {
                final url = f['url'] as String?;
                if (url != null && url.isNotEmpty && !seen.contains(url)) {
                  merged.add({'type': 'image', 'url': url});
                  seen.add(url);
                }
              }
              if (merged.length != existing.length) {
                updateLastMessageWith((m) => m.copyWith(files: merged));
              }
            }
          }
        } catch (_) {}
      } else if (type == 'request:chat:completion' && payload != null) {
        final channel = payload['channel'];
        if (channel is String && channel.isNotEmpty) {
          channelLineHandlerFactory(channel);
        }
      } else if (type == 'execute:tool' && payload != null) {
        // Show an executing tile immediately; also surface any inline files/result
        try {
          final name = payload['name']?.toString() ?? 'tool';
          final status =
              '\n<details type="tool_calls" done="false" name="$name"><summary>Executing...</summary>\n</details>\n';
          appendToLastMessage(status);
          try {
            final filesA = _extractFilesFromResult(payload['files']);
            final filesB = _extractFilesFromResult(payload['result']);
            final all = [...filesA, ...filesB];
            if (all.isNotEmpty) {
              final msgs = getMessages();
              if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
                final existing = msgs.last.files ?? <Map<String, dynamic>>[];
                final seen = <String>{
                  for (final f in existing)
                    if (f['url'] is String) (f['url'] as String) else '',
                }..removeWhere((e) => e.isEmpty);
                final merged = <Map<String, dynamic>>[...existing];
                for (final f in all) {
                  final url = f['url'] as String?;
                  if (url != null && url.isNotEmpty && !seen.contains(url)) {
                    merged.add({'type': 'image', 'url': url});
                    seen.add(url);
                  }
                }
                if (merged.length != existing.length) {
                  updateLastMessageWith((m) => m.copyWith(files: merged));
                }
              }
            }
          } catch (_) {}
        } catch (_) {}
      } else if (type == 'files' && payload != null) {
        // Handle raw files event (image generation results)
        try {
          final files = _extractFilesFromResult(payload);
          if (files.isNotEmpty) {
            final msgs = getMessages();
            if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
              final existing = msgs.last.files ?? <Map<String, dynamic>>[];
              final seen = <String>{
                for (final f in existing)
                  if (f['url'] is String) (f['url'] as String) else '',
              }..removeWhere((e) => e.isEmpty);
              final merged = <Map<String, dynamic>>[...existing];
              for (final f in files) {
                final url = f['url'] as String?;
                if (url != null && url.isNotEmpty && !seen.contains(url)) {
                  merged.add({'type': 'image', 'url': url});
                  seen.add(url);
                }
              }
              if (merged.length != existing.length) {
                updateLastMessageWith((m) => m.copyWith(files: merged));
              }
            }
          }
        } catch (_) {}
      } else if (type == 'event:status' && payload != null) {
        final map = _asStringMap(payload);
        final status = map?['status']?.toString() ?? '';
        if (status.isNotEmpty) {
          updateLastMessageWith(
            (m) => m.copyWith(metadata: {...?m.metadata, 'status': status}),
          );
        }
        final targetId = _resolveTargetMessageId(messageId, getMessages);
        if (map != null && targetId != null) {
          try {
            final statusUpdate = ChatStatusUpdate.fromJson(map);
            appendStatusUpdate(targetId, statusUpdate);
          } catch (_) {}
        }
      } else if (type == 'event:tool' && payload != null) {
        // Accept files from both 'result' and 'files'
        final files = [
          ..._extractFilesFromResult(payload['files']),
          ..._extractFilesFromResult(payload['result']),
        ];
        if (files.isNotEmpty) {
          final msgs = getMessages();
          if (msgs.isNotEmpty && msgs.last.role == 'assistant') {
            final existing = msgs.last.files ?? <Map<String, dynamic>>[];
            final merged = [...existing, ...files];
            updateLastMessageWith((m) => m.copyWith(files: merged));
          }
        }
      } else if (type == 'event:message:delta' && payload != null) {
        final content = payload['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          appendToLastMessage(content);
          triggerHapticFeedback();
          updateImagesFromCurrentContent();
        }
      } else {
        // Log unknown event types to catch any follow-up events we might be missing
        if (type != null && type.toString().contains('follow')) {
          DebugLogger.log(
            'Unknown follow-up related event: $type',
            scope: 'streaming/helper',
          );
        }
      }
    } catch (_) {}
  }

  void channelEventsHandler(
    Map<String, dynamic> ev,
    void Function(dynamic response)? ack,
  ) {
    try {
      final data = ev['data'];
      if (data == null) return;
      final type = data['type'];
      final payload = data['data'];
      if (type == 'message' && payload is Map) {
        final content = payload['content']?.toString() ?? '';
        if (content.isNotEmpty) {
          appendToLastMessage(content);
          updateImagesFromCurrentContent();
        }
      } else {
        // Log channel events that might include follow-ups
        if (type != null && type.toString().contains('follow')) {
          DebugLogger.log(
            'Channel follow-up event: $type',
            scope: 'streaming/helper',
          );
        }
      }
    } catch (_) {}
  }

  // Register WebSocket event handlers unless SSE-only mode
  if (chatStreamingMode != 'sse') {
    if (registerDeltaListener != null) {
      final chatDisposer = registerDeltaListener(
        request: ConversationDeltaRequest.chat(
          conversationId: activeConversationId,
          sessionId: sessionId,
          requireFocus: false,
        ),
        onDelta: (event) {
          socketWatchdog?.ping();
          chatHandler(event.raw, event.ack);
        },
        onError: (error, stackTrace) {
          DebugLogger.error(
            'Chat delta listener error',
            scope: 'streaming/helper',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      socketSubscriptions.add(chatDisposer);
    } else if (socketService != null) {
      final chatSub = socketService.addChatEventHandler(
        conversationId: activeConversationId,
        sessionId: sessionId,
        requireFocus: false,
        handler: chatHandler,
      );
      socketSubscriptions.add(chatSub.dispose);
    }
    if (registerDeltaListener != null) {
      final channelDisposer = registerDeltaListener(
        request: ConversationDeltaRequest.channel(
          conversationId: activeConversationId,
          sessionId: sessionId,
          requireFocus: false,
        ),
        onDelta: (event) {
          socketWatchdog?.ping();
          channelEventsHandler(event.raw, event.ack);
        },
        onError: (error, stackTrace) {
          DebugLogger.error(
            'Channel delta listener error',
            scope: 'streaming/helper',
            error: error,
            stackTrace: stackTrace,
          );
        },
      );
      socketSubscriptions.add(channelDisposer);
    } else if (socketService != null) {
      final channelSub = socketService.addChannelEventHandler(
        conversationId: activeConversationId,
        sessionId: sessionId,
        requireFocus: false,
        handler: channelEventsHandler,
      );
      socketSubscriptions.add(channelSub.dispose);
    }
  } else {
    DebugLogger.log(
      'Skipping WebSocket subscriptions (SSE-only mode)',
      scope: 'streaming/helper',
    );
  }

  final controller = StreamingResponseController(
    stream: persistentController.stream,
    onChunk: (chunk) {
      _chunkCount++;
      _totalCharsReceived += chunk.length;
      
      // Log summary every 20 chunks instead of every chunk
      if (_chunkCount % 20 == 0) {
        DebugLogger.log(
          'Streaming progress: $_chunkCount chunks, $_totalCharsReceived chars',
          scope: 'streaming/progress',
        );
      }
      
      var effectiveChunk = chunk;
      if (webSearchEnabled && !isSearching) {
        if (chunk.contains('[SEARCHING]') ||
            chunk.contains('Searching the web') ||
            chunk.contains('web search')) {
          isSearching = true;
          updateLastMessageWith(
            (message) => message.copyWith(
              content: '🔍 Searching the web...',
              metadata: {'webSearchActive': true},
            ),
          );
          return; // Don't append this chunk
        }
      }

      if (isSearching &&
          (chunk.contains('[/SEARCHING]') ||
              chunk.contains('Search complete'))) {
        isSearching = false;
        updateLastMessageWith(
          (message) => message.copyWith(metadata: {'webSearchActive': false}),
        );
        effectiveChunk = effectiveChunk
            .replaceAll('[SEARCHING]', '')
            .replaceAll('[/SEARCHING]', '');
      }

      if (effectiveChunk.trim().isNotEmpty) {
        appendToLastMessage(effectiveChunk);
        triggerHapticFeedback();
        updateImagesFromCurrentContent();
      }
    },
    onComplete: () {
      // Log streaming summary
      DebugLogger.log(
        'Streaming completed: $_chunkCount chunks, $_totalCharsReceived total chars',
        scope: 'streaming/summary',
      );
      
      api.clearPersistentStreamForMessage(
        assistantMessageId,
        expectedStreamId: streamId,
      );
      // Unregister from persistent service
      persistentService.unregisterStream(streamId);

      // Stream completion without socket subscriptions indicates a simple flow
      // For WebSocket flows, completion should be handled by socket events (done: true)
      if (socketSubscriptions.isEmpty) {
        finishStreaming();
        Future.microtask(refreshConversationSnapshot);
      }
    },
    onError: (error, stackTrace) async {
      DebugLogger.error(
        'Stream error occurred',
        scope: 'streaming/helper',
        error: error,
        data: {
          'conversationId': activeConversationId,
          'messageId': assistantMessageId,
          'modelId': modelId,
        },
      );

      api.clearPersistentStreamForMessage(
        assistantMessageId,
        expectedStreamId: streamId,
      );
      try {
        persistentService.unregisterStream(streamId);
      } catch (_) {}

      // Check if this is a recoverable error (network issues, etc.)
      final errorText = error.toString();
      final isRecoverable =
          (error is! FormatException &&
              errorText.contains('SocketException')) ||
          errorText.contains('TimeoutException') ||
          errorText.contains('HandshakeException');

      if (isRecoverable && socketService != null) {
        // Try to recover via socket connection if available
        try {
          await socketService.ensureConnected(
            timeout: const Duration(seconds: 5),
          );
          // Don't finish streaming immediately - let socket recovery handle it
          socketWatchdog?.stop();
          return;
        } catch (_) {
          // Socket recovery failed, fall through to cleanup
        }
      }

      // Before giving up, check if backend completed (like a manual reload)
      // But only if we don't already have content
      final currentMsgs = getMessages();
      if (currentMsgs.isNotEmpty && 
          currentMsgs.last.role == 'assistant' &&
          currentMsgs.last.content.trim().isNotEmpty) {
        DebugLogger.stream('Content already present after error - no fetch needed');
      } else {
        // Wait a bit to give backend time to finish processing
        await Future.delayed(const Duration(seconds: 2));
        await refreshConversationSnapshot();
      }

      disposeSocketSubscriptions();
      finishStreaming();
      socketWatchdog?.stop();
    },
  );

  return ActiveSocketStream(
    controller: controller,
    socketSubscriptions: socketSubscriptions,
    disposeWatchdog: () => socketWatchdog?.stop(),
  );
}

List<Map<String, dynamic>> _extractFilesFromResult(dynamic resp) {
  final results = <Map<String, dynamic>>[];
  if (resp == null) return results;
  dynamic r = resp;
  if (r is String) {
    try {
      r = jsonDecode(r);
    } catch (_) {}
  }
  if (r is List) {
    for (final item in r) {
      if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      } else if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      }
    }
    return results;
  }
  if (r is! Map) return results;
  final data = r['data'];
  if (data is List) {
    for (final item in data) {
      if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      } else if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      }
    }
  }
  final images = r['images'];
  if (images is List) {
    for (final item in images) {
      if (item is String && item.isNotEmpty) {
        results.add({'type': 'image', 'url': item});
      } else if (item is Map) {
        final url = item['url'];
        final b64 = item['b64_json'] ?? item['b64'];
        if (url is String && url.isNotEmpty) {
          results.add({'type': 'image', 'url': url});
        } else if (b64 is String && b64.isNotEmpty) {
          results.add({'type': 'image', 'url': 'data:image/png;base64,$b64'});
        }
      }
    }
  }
  final files = r['files'];
  if (files is List) {
    results.addAll(_extractFilesFromResult(files));
  }
  final singleUrl = r['url'];
  if (singleUrl is String && singleUrl.isNotEmpty) {
    results.add({'type': 'image', 'url': singleUrl});
  }
  final singleB64 = r['b64_json'] ?? r['b64'];
  if (singleB64 is String && singleB64.isNotEmpty) {
    results.add({'type': 'image', 'url': 'data:image/png;base64,$singleB64'});
  }
  return results;
}

Map<String, dynamic>? _asStringMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return null;
}

List<dynamic>? _normalizeSourcesPayload(dynamic raw) {
  if (raw == null) {
    return null;
  }
  if (raw is List) {
    return raw;
  }
  if (raw is Iterable) {
    return raw.toList(growable: false);
  }
  if (raw is Map) {
    return [raw];
  }
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded;
      }
      if (decoded is Map) {
        return [decoded];
      }
    } catch (_) {}
  }
  return null;
}

String? _resolveTargetMessageId(
  String? messageId,
  List<ChatMessage> Function() getMessages,
) {
  if (messageId != null && messageId.isNotEmpty) {
    return messageId;
  }
  final messages = getMessages();
  if (messages.isEmpty) {
    return null;
  }
  return messages.last.id;
}

List<String> _parseFollowUpsField(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<dynamic>()
        .map((value) => value?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    return [raw.trim()];
  }
  return const <String>[];
}

void _showSocketNotification(String type, String content) {
  if (content.isEmpty) return;
  final ctx = NavigationService.context;
  if (ctx == null) return;
  final theme = Theme.of(ctx);
  Color background;
  Color foreground;
  switch (type) {
    case 'success':
      background = theme.colorScheme.primary;
      foreground = theme.colorScheme.onPrimary;
      break;
    case 'error':
      background = theme.colorScheme.error;
      foreground = theme.colorScheme.onError;
      break;
    case 'warning':
    case 'warn':
      background = theme.colorScheme.tertiary;
      foreground = theme.colorScheme.onTertiary;
      break;
    default:
      background = theme.colorScheme.secondary;
      foreground = theme.colorScheme.onSecondary;
  }

  final snackBar = SnackBar(
    content: Text(content, style: TextStyle(color: foreground)),
    backgroundColor: background,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 4),
  );

  ScaffoldMessenger.of(ctx)
    ..removeCurrentSnackBar()
    ..showSnackBar(snackBar);
}

Future<bool> _showConfirmationDialog(Map<String, dynamic> data) async {
  final ctx = NavigationService.context;
  if (ctx == null) return false;
  final title = data['title']?.toString() ?? 'Confirm';
  final message = data['message']?.toString() ?? '';
  final confirmText = data['confirm_text']?.toString() ?? 'Confirm';
  final cancelText = data['cancel_text']?.toString() ?? 'Cancel';

  return ThemedDialogs.confirm(
    ctx,
    title: title,
    message: message,
    confirmText: confirmText,
    cancelText: cancelText,
    barrierDismissible: false,
  );
}

Future<String?> _showInputDialog(Map<String, dynamic> data) async {
  final ctx = NavigationService.context;
  if (ctx == null) return null;
  final title = data['title']?.toString() ?? 'Input Required';
  final message = data['message']?.toString() ?? '';
  final placeholder = data['placeholder']?.toString() ?? '';
  final initialValue = data['value']?.toString() ?? '';
  final controller = TextEditingController(text: initialValue);

  final result = await showDialog<String>(
    context: ctx,
    barrierDismissible: false,
    builder: (dialogCtx) {
      return ThemedDialogs.buildBase(
        context: dialogCtx,
        title: title,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty) ...[
              Text(
                message,
                style: TextStyle(color: dialogCtx.conduitTheme.textSecondary),
              ),
              const SizedBox(height: Spacing.md),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: placeholder.isNotEmpty
                    ? placeholder
                    : 'Enter a value',
              ),
              onSubmitted: (value) {
                Navigator.of(
                  dialogCtx,
                ).pop(value.trim().isEmpty ? null : value.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(null),
            child: Text(
              data['cancel_text']?.toString() ?? 'Cancel',
              style: TextStyle(color: dialogCtx.conduitTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isEmpty) {
                Navigator.of(dialogCtx).pop(null);
              } else {
                Navigator.of(dialogCtx).pop(trimmed);
              }
            },
            child: Text(
              data['confirm_text']?.toString() ?? 'Submit',
              style: TextStyle(color: dialogCtx.conduitTheme.buttonPrimary),
            ),
          ),
        ],
      );
    },
  );

  controller.dispose();
  if (result == null) return null;
  final trimmed = result.trim();
  return trimmed.isEmpty ? null : trimmed;
}
