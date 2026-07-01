import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../audio/gateway_live_client.dart';
import '../../audio/pcm_stream_speaker.dart';
import '../../config/gateway_providers.dart';
import '../../router/gateway_router_providers.dart';
import '../../transport/gateway_client.dart';
import '../domain/realtime_call_step.dart';
import 'call_background_lease.dart';
import 'realtime_tool_executor.dart';

class RealtimeCallSession extends Notifier<RealtimeCallSessionState> {
  final AudioRecorder _recorder = AudioRecorder();
  late final PcmStreamSpeaker _speaker = PcmStreamSpeaker(
    iosAudioCategory: IosAudioCategory.playAndRecord,
    logScope: 'call/live',
  );

  GatewayLiveClient? _client;
  CallBackgroundLease? _backgroundLease;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<LiveEvent>? _eventsSub;
  StreamController<Uint8List>? _audioController;
  Map<String, ik.ToolSpec> _toolsByName = const {};

  bool _alive = true;
  bool _muted = false;

  @override
  RealtimeCallSessionState build() {
    ref.onDispose(_teardown);
    unawaited(WakelockPlus.enable());
    Future.microtask(_connect);
    return RealtimeCallSessionState.initial;
  }

  Future<void> togglePause() async {
    HapticFeedback.lightImpact();
    _muted = !_muted;
    state = state.copyWith(muted: _muted);
  }

  Future<void> end() async {
    if (!_alive) return;
    await _teardown();
  }

  Future<void> _connect() async {
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

    final tools = await ref.read(gatewayToolRegistryProvider).buildTools(
      config: cfg,
      owuiBaseUrl: ref.read(apiServiceProvider)?.baseUrl,
      owuiAuthToken: ref.read(apiServiceProvider)?.authToken,
    );
    if (!_alive) return;
    _toolsByName = {for (final t in tools) t.name: t};

    final client = GatewayLiveClient(client: ref.read(gatewayClientProvider));
    _client = client;
    try {
      await client.start(
        systemInstruction: cfg.callSystemPrompt,
        tools: tools,
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

    _backgroundLease = CallBackgroundLease();
    unawaited(_backgroundLease!.acquire());

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
        if (_alive && state.step != RealtimeCallStep.error) {
          _emitError('Connection closed.');
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

    HapticFeedback.lightImpact();
    state = state.copyWith(
      step: RealtimeCallStep.live,
      connected: true,
      clearError: true,
    );
  }

  void _onLiveEvent(LiveEvent event) {
    if (!_alive) return;
    switch (event) {
      case LiveAudioChunk(:final bytes):
        _playChunk(bytes);
      case LiveInputTranscript(:final text):
        state = state.copyWith(inputTranscript: text);
      case LiveOutputTranscript(:final text):
        state = state.copyWith(outputTranscript: text);
      case LiveInterrupted():
        _stopPlaybackForInterrupt();
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

  // PcmStreamSpeaker.stream() auto-supersedes any in-flight call, so opening a fresh one on interrupt/next-turn quietly resolves the previous future instead of erroring. [fact]
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
                if (_alive) state = state.copyWith(speaking: true);
              },
            )
            .then((_) {
              if (_alive) state = state.copyWith(speaking: false);
            }),
      );
    }
    if (!controller.isClosed) controller.add(bytes);
  }

  Future<void> _handleToolCall(List<LiveFunctionCall> calls) async {
    if (!_alive) return;
    state = state.copyWith(runningTool: calls.map((c) => c.name).join(', '));
    final responses = await executeLiveToolCalls(calls, _toolsByName);
    if (!_alive) return;
    state = state.copyWith(clearRunningTool: true);
    _client?.sendToolResponse(responses);
  }

  void _endTurnAudio() {
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
  }

  void _emitError(String message) {
    HapticFeedback.heavyImpact();
    state = state.copyWith(
      step: RealtimeCallStep.error,
      errorMessage: message,
      connected: false,
    );
  }

  Future<void> _teardown() async {
    _alive = false;
    unawaited(WakelockPlus.disable());

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
    NotifierProvider.autoDispose<RealtimeCallSession, RealtimeCallSessionState>(
  RealtimeCallSession.new,
);
