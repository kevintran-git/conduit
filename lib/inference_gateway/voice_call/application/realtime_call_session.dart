import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/semantic_message_builder.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../features/chat/providers/chat_providers.dart' as chat;
import '../../../features/tools/providers/tools_providers.dart';
import '../../audio/gateway_live_client.dart';
import '../../audio/native_call_audio_track.dart';
import '../../audio/pcm_stream_speaker.dart';
import '../../config/gateway_providers.dart';
import '../../router/gateway_router_providers.dart';
import '../../transport/gateway_client.dart';
import '../domain/call_step.dart';
import 'call_background_lease.dart';
import 'call_engine.dart';
import 'realtime_tool_executor.dart';

const String _directServerPrefix = 'direct_server:';
const String _adminToolServerPrefix = 'server:';

class RealtimeCallSession extends Notifier<CallSessionState>
    implements CallEngine {
  final AudioRecorder _recorder = AudioRecorder();
  late final PcmStreamSpeaker _speaker = PcmStreamSpeaker(
    iosAudioCategory: IosAudioCategory.playAndRecord,
    logScope: 'call/live',
    sink: Platform.isAndroid ? NativeCallAudioTrack() : null,
  );

  GatewayLiveClient? _client;
  CallBackgroundLease? _backgroundLease;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<LiveEvent>? _eventsSub;
  StreamController<Uint8List>? _audioController;
  Map<String, ik.ToolSpec> _toolsByName = const {};

  bool _alive = true;
  bool _muted = false;
  bool _activityOpen = false;
  bool _connectedManualMode = false;
  DateTime? _lastFirstFrameAt;
  bool _freshUserTurn = true;
  bool _freshAssistantTurn = true;

  String? _pendingUserMessageId;
  String? _pendingAssistantMessageId;
  Future<void>? _pendingConversationPromotion;
  final List<String> _toolBlocksSoFar = [];
  final Map<String, int> _toolBlockIndexById = {};

  @override
  CallSessionState build() {
    ref.onDispose(_teardown);
    unawaited(WakelockPlus.enable());
    ref.read(gatewayInferenceRouterProvider).markCallStart();
    Future.microtask(_connect);
    return CallSessionState(
      isLive: true,
      manualEosOnly: ref.read(gatewayConfigProvider).voiceManualMode,
    );
  }

  @override
  Future<void> tapMicButton() async {
    switch (state.step) {
      case CallStep.speaking:
        HapticFeedback.heavyImpact();
        _stopPlaybackForInterrupt();
        if (_connectedManualMode) {
          _client?.sendActivityStart();
          _activityOpen = true;
        }
        break;
      case CallStep.listening:
        if (!_connectedManualMode) return;
        HapticFeedback.mediumImpact();
        if (_activityOpen) {
          _client?.sendActivityEnd();
          _activityOpen = false;
        } else {
          _client?.sendActivityStart();
          _activityOpen = true;
        }
        break;
      case CallStep.idle:
      case CallStep.thinking:
      case CallStep.error:
        break;
    }
  }

  @override
  Future<void> toggleMute() async {
    HapticFeedback.lightImpact();
    _muted = !_muted;
    state = state.copyWith(muted: _muted);
    if (_muted && !_connectedManualMode) _client?.sendAudioStreamEnd();
  }

  @override
  Future<void> setManualEosOnly(bool value) async {
    if (state.manualEosOnly == value || state.reconnecting) return;
    state = state.copyWith(manualEosOnly: value);
    final cfg = ref.read(gatewayConfigProvider);
    if (cfg.voiceManualMode != value) {
      await ref.read(gatewayConfigProvider.notifier).setVoiceManualMode(value);
    }
    if (state.step == CallStep.idle) return;
    await _reconnectForModeChange();
  }

  @override
  Future<void> end() async {
    if (!_alive) return;
    await _teardown();
  }

  void _ensureTurnMessages() {
    if (_pendingAssistantMessageId != null) return;

    final userId = const Uuid().v4();
    final assistantId = const Uuid().v4();
    final priorMessages = ref.read(chat.chatMessagesProvider);
    final parentId = priorMessages.isNotEmpty ? priorMessages.last.id : null;
    final cfg = ref.read(gatewayConfigProvider);

    final userMessage = ChatMessage(
      id: userId,
      role: 'user',
      content: '🎙️ ${state.partialTranscript.trim()}',
      timestamp: DateTime.now(),
      metadata: {'parentId': parentId, 'childrenIds': <String>[assistantId]},
    );
    final assistantPlaceholder = ChatMessage(
      id: assistantId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      model: cfg.callModel,
      isStreaming: true,
      metadata: {'parentId': userId, 'childrenIds': const <String>[]},
    );

    ref.read(chat.chatMessagesProvider.notifier).addMessages([
      userMessage,
      assistantPlaceholder,
    ]);
    _pendingUserMessageId = userId;
    _pendingAssistantMessageId = assistantId;
    _toolBlocksSoFar.clear();
    _toolBlockIndexById.clear();

    if (ref.read(activeConversationProvider) == null) {
      final localConversation = Conversation(
        id: const Uuid().v4(),
        title: 'New Chat',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: [userMessage, assistantPlaceholder],
      );
      ref.read(activeConversationProvider.notifier).set(localConversation);
      _pendingConversationPromotion = _promoteToServerConversation(
        localConversation,
        userMessage,
      );
    }
  }

  Future<void> _promoteToServerConversation(
    Conversation localConversation,
    ChatMessage firstUserMessage,
  ) async {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    try {
      final serverConversation = await api.createConversation(
        title: 'New Chat',
        messages: [firstUserMessage],
        model: ref.read(gatewayConfigProvider).callModel,
      );
      if (!_alive) return;
      final current = ref.read(activeConversationProvider);
      if (current == null || current.id != localConversation.id) return;
      ref
          .read(activeConversationProvider.notifier)
          .set(current.copyWith(id: serverConversation.id));
    } catch (error, stackTrace) {
      DebugLogger.error(
        'voice-conversation-create-failed',
        scope: 'call/live',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  String _composeAssistantContent() {
    final buffer = StringBuffer();
    for (final block in _toolBlocksSoFar) {
      buffer
        ..write(block)
        ..write('\n\n');
    }
    buffer.write(state.outputTranscript);
    return buffer.toString();
  }

  void _syncAssistantContent() {
    final id = _pendingAssistantMessageId;
    if (id == null) return;
    final content = _composeAssistantContent();
    ref
        .read(chat.chatMessagesProvider.notifier)
        .updateMessageById(id, (m) => m.copyWith(content: content));
  }

  Future<void> _finalizePendingTurn() async {
    final id = _pendingAssistantMessageId;
    if (id != null) {
      final promotion = _pendingConversationPromotion;
      if (promotion != null) {
        try {
          await promotion;
        } catch (_) {}
        _pendingConversationPromotion = null;
      }
      try {
        _syncAssistantContent();
        ref.read(chat.chatMessagesProvider.notifier).finishStreaming();
      } catch (_) {}
    }
    _pendingUserMessageId = null;
    _pendingAssistantMessageId = null;
    _toolBlocksSoFar.clear();
    _toolBlockIndexById.clear();
  }

  Future<void> _reconnectForModeChange() async {
    if (!_alive) return;
    final resumeHandle = _client?.lastResumptionHandle;
    state = state.copyWith(reconnecting: true);
    await _teardownConnection();
    if (!_alive) return;
    await _connect(resumeHandle: resumeHandle);
  }

  Future<void> _teardownConnection() async {
    await _finalizePendingTurn();
    final client = _client;
    final micSub = _micSub;
    final eventsSub = _eventsSub;
    _client = null;
    _micSub = null;
    _eventsSub = null;
    _activityOpen = false;
    _stopPlaybackForInterrupt();
    try {
      await eventsSub?.cancel();
    } catch (_) {}
    try {
      await micSub?.cancel();
    } catch (_) {}
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await client?.dispose();
    } catch (_) {}
  }

  Future<void> _connect({String? resumeHandle}) async {
    final cfg = ref.read(gatewayConfigProvider);
    if (!cfg.realtimeEnabled || !cfg.hasCredentials) {
      _emitError('Realtime voice is not configured.');
      return;
    }

    final hasMic = await _recorder.hasPermission();
    if (!_alive) return;
    if (!hasMic) {
      _emitError('Mic access denied. Enable it in Settings to use voice.');
      return;
    }

    final selectedIds = ref.read(selectedToolIdsProvider);
    final selectedToolServerKeys = selectedIds
        .where((id) => id.startsWith(_directServerPrefix))
        .map((id) => id.substring(_directServerPrefix.length).trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final includeAdminToolServers = selectedIds.any(
      (id) => id.startsWith(_adminToolServerPrefix),
    );
    final tools = await ref.read(gatewayToolRegistryProvider).buildTools(
      config: cfg,
      owuiBaseUrl: ref.read(apiServiceProvider)?.baseUrl,
      owuiAuthToken: ref.read(apiServiceProvider)?.authToken,
      selectedToolServerKeys: selectedToolServerKeys,
      includeAdminToolServers: includeAdminToolServers,
    );
    if (!_alive) return;
    _toolsByName = {for (final t in tools) t.name: t};
    state = state.copyWith(
      activeToolNames: tools.map((t) => t.name).toList(growable: false),
    );

    final manualMode = state.manualEosOnly;
    final client = GatewayLiveClient(client: ref.read(gatewayClientProvider));
    _client = client;
    try {
      await client.start(
        model: cfg.callModel,
        systemInstruction: cfg.callSystemPrompt,
        voiceName: cfg.callVoice,
        silenceDurationMs: cfg.callPauseToleranceMs,
        prefixPaddingMs: cfg.callPrefixPaddingMs,
        startOfSpeechSensitivity: cfg.callStartSensitivity,
        endOfSpeechSensitivity: cfg.callEndSensitivity,
        tools: tools,
        disableAutomaticActivityDetection: manualMode,
        resumeHandle: resumeHandle,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'connect-failed',
        scope: 'call/live',
        error: error,
        stackTrace: stackTrace,
      );
      _emitError('Could not connect to the realtime voice service.');
      return;
    }
    if (!_alive) return;

    if (_backgroundLease == null) {
      _backgroundLease = CallBackgroundLease();
      unawaited(_backgroundLease!.acquire());
    }

    _eventsSub = client.events.listen(
      _onLiveEvent,
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'events-error',
          scope: 'call/live',
          error: error,
          stackTrace: stackTrace,
        );
        if (_alive) _emitError('Connection lost.');
      },
      onDone: () {
        if (_alive && state.step != CallStep.error) {
          _emitError(client.lastCloseMessage ?? 'Connection closed.');
        }
      },
    );

    try {
      final pcmStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          streamBufferSize: 1600,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeInCommunication,
            speakerphone: true,
          ),
        ),
      );
      if (!_alive) return;
      _micSub = pcmStream.listen((chunk) {
        if (!_muted) client.sendAudioChunk(chunk);
      });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'mic-start-failed',
        scope: 'call/live',
        error: error,
        stackTrace: stackTrace,
      );
      _emitError('Could not start the microphone.');
      return;
    }

    if (!_alive || state.step == CallStep.error) return;
    _connectedManualMode = manualMode;
    HapticFeedback.lightImpact();
    state = state.copyWith(
      step: CallStep.listening,
      sttReady: true,
      clearError: true,
      reconnecting: false,
    );
  }

  void _onLiveEvent(LiveEvent event) {
    if (!_alive) return;
    switch (event) {
      case LiveAudioChunk(:final bytes):
        _playChunk(bytes);
      case LiveInputTranscript(:final text):
        final base = _freshUserTurn ? '' : state.partialTranscript;
        _freshUserTurn = false;
        state = state.copyWith(partialTranscript: base + text);
        final userId = _pendingUserMessageId;
        if (userId != null) {
          ref
              .read(chat.chatMessagesProvider.notifier)
              .updateMessageById(
                userId,
                (m) => m.copyWith(content: state.partialTranscript.trim()),
              );
        }
      case LiveOutputTranscript(:final text):
        final base = _freshAssistantTurn ? '' : state.outputTranscript;
        _freshAssistantTurn = false;
        state = state.copyWith(outputTranscript: base + text);
        _ensureTurnMessages();
        _syncAssistantContent();
      case LiveInterrupted():
        _handleInterrupted();
      case LiveTurnComplete():
        _endTurnAudio();
      case LiveToolCall(:final calls):
        unawaited(_handleToolCall(calls));
      case LiveError(:final message):
        DebugLogger.warning(
          'live-error',
          scope: 'call/live',
          data: {'message': message},
        );
    }
  }

  void _handleInterrupted() {
    final firstFrameAt = _lastFirstFrameAt;
    if (firstFrameAt != null) {
      final sinceFirstFrame = DateTime.now().difference(firstFrameAt);
      if (sinceFirstFrame < const Duration(milliseconds: 300)) {
        DebugLogger.warning(
          'suspect-self-interrupt',
          scope: 'call/live',
          data: {'msSinceFirstFrame': sinceFirstFrame.inMilliseconds},
        );
      }
    }
    unawaited(_finalizePendingTurn());
    _freshUserTurn = true;
    _freshAssistantTurn = true;
    _stopPlaybackForInterrupt();
  }

  void _playChunk(Uint8List bytes) {
    var controller = _audioController;
    if (controller == null) {
      controller = StreamController<Uint8List>();
      _audioController = controller;
      unawaited(
        _speaker
            .stream(
              controller.stream,
              onFirstFrame: () {
                if (!_alive) return;
                _lastFirstFrameAt = DateTime.now();
                HapticFeedback.lightImpact();
                state = state.copyWith(step: CallStep.speaking);
                _ensureTurnMessages();
              },
            )
            .then((_) {
              if (_alive && state.step == CallStep.speaking) {
                state = state.copyWith(step: CallStep.listening);
              }
            }),
      );
    }
    if (!controller.isClosed) controller.add(bytes);
  }

  Future<void> _handleToolCall(List<LiveFunctionCall> calls) async {
    if (!_alive) return;
    state = state.copyWith(runningTool: calls.map((c) => c.name).join(', '));
    _ensureTurnMessages();
    for (final call in calls) {
      _toolBlockIndexById[call.id] = _toolBlocksSoFar.length;
      _toolBlocksSoFar.add(_toolCallBlock(call, done: false));
    }
    _syncAssistantContent();

    final responses = await executeLiveToolCalls(calls, _toolsByName);
    if (!_alive) return;
    state = state.copyWith(clearRunningTool: true);
    for (final response in responses) {
      final index = _toolBlockIndexById[response.id];
      final call = calls.where((c) => c.id == response.id).firstOrNull;
      if (index != null && call != null && index < _toolBlocksSoFar.length) {
        _toolBlocksSoFar[index] = _toolCallBlock(
          call,
          done: true,
          result: response.response,
        );
      }
    }
    _syncAssistantContent();
    _client?.sendToolResponse(responses);
  }

  String _toolCallBlock(LiveFunctionCall call, {required bool done, Object? result}) {
    return renderSemanticMessageBlocks([
      SemanticDetailsBlock.toolCall(
        id: call.id,
        name: call.name,
        arguments: call.args,
        done: done,
        result: result,
      ),
    ]);
  }

  void _endTurnAudio() {
    unawaited(_finalizePendingTurn());
    _freshUserTurn = true;
    _freshAssistantTurn = true;
    final controller = _audioController;
    _audioController = null;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  void _stopPlaybackForInterrupt() {
    final controller = _audioController;
    _audioController = null;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
    unawaited(_speaker.stop(hardFlush: true));
    if (_alive && state.step == CallStep.speaking) {
      state = state.copyWith(step: CallStep.listening);
    }
  }

  void _emitError(String message) {
    HapticFeedback.heavyImpact();
    state = state.copyWith(step: CallStep.error, errorMessage: message);
  }

  Future<void> _teardown() async {
    await _finalizePendingTurn();
    _alive = false;
    unawaited(WakelockPlus.disable());
    ref.read(gatewayInferenceRouterProvider).markCallEnd();

    final client = _client;
    final backgroundLease = _backgroundLease;
    final micSub = _micSub;
    final eventsSub = _eventsSub;
    final audioController = _audioController;
    _client = null;
    _backgroundLease = null;
    _micSub = null;
    _eventsSub = null;
    _audioController = null;

    unawaited(() async {
      try {
        await eventsSub?.cancel();
      } catch (_) {}
      try {
        await micSub?.cancel();
      } catch (_) {}
      try {
        await _recorder.stop();
      } catch (_) {}
      try {
        await _recorder.dispose();
      } catch (_) {}
      if (audioController != null && !audioController.isClosed) {
        try {
          await audioController.close();
        } catch (_) {}
      }
      try {
        await _speaker.dispose();
      } catch (_) {}
      try {
        await client?.dispose();
      } catch (_) {}
      try {
        await backgroundLease?.release();
      } catch (_) {}
    }());
  }
}

final realtimeCallSessionProvider =
    NotifierProvider.autoDispose<RealtimeCallSession, CallSessionState>(
  RealtimeCallSession.new,
);
