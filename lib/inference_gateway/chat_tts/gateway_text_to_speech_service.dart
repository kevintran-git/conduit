import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../features/chat/services/text_to_speech_service.dart';
import '../../features/chat/services/tts_manager.dart';
import '../../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../config/gateway_providers.dart';
import '../router/gateway_router_providers.dart';
import '../read_aloud/presentation/read_aloud_overlay.dart';
import '../read_aloud/read_aloud_engine.dart';
import '../read_aloud/speech_text.dart';
import 'gateway_chat_tts_speaker.dart';

class GatewayTextToSpeechService extends TextToSpeechService {
  GatewayTextToSpeechService({
    required Ref ref,
    super.serverSpeech,
    super.backendConfig,
    super.loadBackendConfig,
  }) : _ref = ref;

  final Ref _ref;
  GatewayChatTtsSpeaker? _speaker;
  ik.ElevenLabsTtsClient? _speakerClient;
  ReadAloudEngine? _engine;
  ik.ElevenLabsTtsClient? _engineClient;
  ReadAloudOverlayHost? _overlay;

  final ValueNotifier<ReadAloudSnapshot?> readAloud = ValueNotifier(null);

  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;
  void Function(int sentenceIndex)? _onSentenceIndex;
  void Function(int start, int end)? _onWordProgress;

  int _lastPart = -1;
  bool _pauseNotified = false;

  bool get _gatewayActive => _ref.read(gatewayTtsActiveProvider);

  bool get _readAloudActive => _engine?.isActive ?? false;

  GatewayChatTtsSpeaker _ensureSpeaker() {
    final liveClient = _ref.read(gatewayElevenLabsClientProvider);
    if (_speaker != null && !identical(_speakerClient, liveClient)) {
      unawaited(_speaker!.dispose());
      _speaker = null;
    }
    _speakerClient = liveClient;
    return _speaker ??= GatewayChatTtsSpeaker(
      client: liveClient,
      config: _ref.read(gatewayConfigProvider),
    );
  }

  Future<ReadAloudEngine> _ensureEngine() async {
    final liveClient = _ref.read(gatewayElevenLabsClientProvider);
    final stale = _engine;
    if (stale != null && !identical(_engineClient, liveClient)) {
      _engine = null;
      await stale.dispose();
      readAloud.value = null;
    }
    _engineClient = liveClient;
    final existing = _engine;
    if (existing != null) return existing;
    final engine = ReadAloudEngine(client: liveClient);
    engine.onStarted = () => _onStart?.call();
    engine.onStatus = _handleReadAloudStatus;
    engine.onCompleted = () {
      _lastPart = -1;
      _onComplete?.call();
      _releaseWakelockIfIdle();
    };
    engine.onError = (message) {
      _lastPart = -1;
      _onError?.call(message);
      _releaseWakelockIfIdle();
    };
    engine.onWord = (part, start, end) {
      if (part != _lastPart) {
        _lastPart = part;
        _onSentenceIndex?.call(part);
      }
      _onWordProgress?.call(start, end);
    };
    engine.snapshot.addListener(() {
      if (identical(_engine, engine)) readAloud.value = engine.snapshot.value;
    });
    return _engine = engine;
  }

  void _handleReadAloudStatus(ReadAloudStatus status) {
    switch (status) {
      case ReadAloudStatus.playing:
        unawaited(WakelockPlus.enable());
        if (_pauseNotified) {
          _pauseNotified = false;
          _onContinue?.call();
        }
      case ReadAloudStatus.paused:
        _pauseNotified = true;
        _onPause?.call();
        _releaseWakelockIfIdle();
      case ReadAloudStatus.loading:
        break;
    }
  }

  @override
  void bindHandlers({
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onCancel,
    VoidCallback? onPause,
    VoidCallback? onContinue,
    void Function(String message)? onError,
    void Function(int sentenceIndex)? onSentenceIndex,
    void Function(int start, int end)? onDeviceWordProgress,
  }) {
    _onStart = onStart;
    _onComplete = onComplete;
    _onCancel = onCancel;
    _onPause = onPause;
    _onContinue = onContinue;
    _onError = onError;
    _onSentenceIndex = onSentenceIndex;
    _onWordProgress = onDeviceWordProgress;
    super.bindHandlers(
      onStart: onStart,
      onComplete: onComplete,
      onCancel: onCancel,
      onPause: onPause,
      onContinue: onContinue,
      onError: onError,
      onSentenceIndex: onSentenceIndex,
      onDeviceWordProgress: onDeviceWordProgress,
    );
  }

  @override
  Future<void> speak(String text) async {
    if (!_gatewayActive) {
      await _speaker?.stop();
      await _engine?.stop();
      await super.speak(text);
      return;
    }
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot speak empty text');
    }
    DebugLogger.log(
      'speak-via-gateway',
      scope: 'gateway/chat-tts',
      data: {'text_len': text.length},
    );
    await _speaker?.stop();
    final config = _ref.read(gatewayConfigProvider);
    _lastPart = -1;
    _pauseNotified = false;
    _overlay ??= ReadAloudOverlayHost(service: this);
    unawaited(WakelockPlus.enable());
    final engine = await _ensureEngine();
    await engine.play(
      text: text,
      parts: splitTextForSpeech(text),
      voice: config.ttsVoice,
      model: config.ttsModel,
      pronunciations: parsePronunciations(config.ttsPronunciations),
    );
    if (!engine.isActive) _releaseWakelockIfIdle();
  }

  @override
  Future<void> startStreamingTts() async {
    if (!_gatewayActive) {
      await super.startStreamingTts();
      return;
    }
    DebugLogger.log('stream-start-via-gateway', scope: 'gateway/chat-tts');
    await _engine?.stop();
    unawaited(WakelockPlus.enable());
    await _ensureSpeaker().startStream(
      onStart: _onStart,
      onComplete: _onComplete,
      onError: _onError,
    );
  }

  @override
  Future<void> feedStreamingText(String accumulatedText) async {
    if (!_gatewayActive) {
      await super.feedStreamingText(accumulatedText);
      return;
    }
    _speaker?.feed(accumulatedText);
  }

  @override
  Future<void> finishStreamingTts({String? finalText}) async {
    if (!_gatewayActive) {
      await super.finishStreamingTts(finalText: finalText);
      return;
    }
    try {
      await _speaker?.finishStream(finalText: finalText);
    } finally {
      _releaseWakelockIfIdle();
    }
  }

  @override
  Future<void> stopStreamingTts() async {
    if (!_gatewayActive) {
      await super.stopStreamingTts();
      return;
    }
    await _speaker?.stop();
    _onCancel?.call();
    _releaseWakelockIfIdle();
  }

  void _releaseWakelockIfIdle() {
    final callActive = _ref.read(chatVoiceModeControllerProvider).isActive;
    if (!callActive) {
      unawaited(WakelockPlus.disable());
    }
  }

  @override
  Future<void> stop() async {
    if (_speaker != null || _engine != null) {
      await _engine?.stop();
      await _speaker?.stop();
      _lastPart = -1;
      _pauseNotified = false;
      _onCancel?.call();
      _releaseWakelockIfIdle();
    }
    await super.stop();
  }

  @override
  Future<void> pause() async {
    if (_readAloudActive) {
      await _engine!.pause();
      return;
    }
    if (_gatewayActive && (_speaker?.isStreaming ?? false)) {
      await _speaker!.stop();
      _onCancel?.call();
      _releaseWakelockIfIdle();
      return;
    }
    await super.pause();
  }

  @override
  Future<void> resume() async {
    if (_readAloudActive) {
      unawaited(WakelockPlus.enable());
      await _engine!.resume();
      return;
    }
    if (_gatewayActive) return;
    await super.resume();
  }

  bool get readAloudPaused => _engine?.isPaused ?? false;

  Future<void> togglePause() => readAloudPaused ? resume() : pause();

  Future<void> seek(Duration position) async {
    await _engine?.seekTo(position);
  }

  Future<void> skipBy(Duration delta) async {
    await _engine?.skipBy(delta);
  }

  Future<void> skipSegments(int delta) async {
    await _engine?.skipSegments(delta);
  }

  Future<void> playSegment(int segment, {int word = 0}) async {
    if (_engine?.isPaused ?? false) unawaited(WakelockPlus.enable());
    await _engine?.playSegment(segment, word: word);
  }

  @override
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_gatewayActive) return super.getAvailableVoices();
    final cfg = _ref.read(gatewayConfigProvider);
    return [
      {'name': cfg.ttsVoice, 'identifier': cfg.ttsVoice, 'locale': 'en-US'},
    ];
  }

  @override
  Future<void> dispose() async {
    _overlay?.dispose();
    _overlay = null;
    await _speaker?.dispose();
    _speaker = null;
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
    readAloud.dispose();
    await super.dispose();
  }
}

TextToSpeechService createGatewayTextToSpeechService(Ref ref) {
  BackendConfig? readBackendConfig() {
    return ref
        .read(backendConfigProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
  }

  final service = GatewayTextToSpeechService(
    ref: ref,
    serverSpeech: ref.read(serverSpeechProviderProvider),
    backendConfig: readBackendConfig(),
    loadBackendConfig: () async {
      await ref.read(backendConfigProvider.notifier).refresh();
      return readBackendConfig();
    },
  );
  ref.listen(serverSpeechProviderProvider, (_, next) {
    TtsManager.instance.setServerSpeech(next);
  });
  ref.listen(backendConfigProvider, (_, next) {
    service.setBackendConfig(
      next.maybeWhen(data: (value) => value, orElse: () => null),
    );
  });
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
}
