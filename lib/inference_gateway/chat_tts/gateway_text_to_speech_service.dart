import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/backend_config.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/debug_logger.dart';
import '../../features/chat/services/text_to_speech_service.dart';
import '../../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../config/gateway_providers.dart';
import '../router/gateway_router_providers.dart';
import 'gateway_chat_tts_speaker.dart';

/// [TextToSpeechService] subclass that routes speech through the gateway's
/// ElevenLabs WS when gateway TTS is active — both the chat-message speaker
/// button ([speak]) and the incremental path upstream's voice mode drives
/// ([startStreamingTts] / [feedStreamingText] / [finishStreamingTts]).
///
/// Lets both benefit from first-byte playback rather than waiting on a full
/// PCM blob per chunk like upstream's TtsManager. Falls through to the parent
/// implementation (TtsManager → device / OWUI server) whenever the gateway is
/// off, so existing behavior is preserved for non-gateway users.
///
/// Touches no upstream files — wired in by overriding
/// `textToSpeechServiceProvider` in the root `ProviderScope`.
class GatewayTextToSpeechService extends TextToSpeechService {
  GatewayTextToSpeechService({
    required Ref ref,
    super.api,
    super.backendConfig,
    super.loadBackendConfig,
  }) : _ref = ref;

  final Ref _ref;
  GatewayChatTtsSpeaker? _speaker;
  ik.ElevenLabsTtsClient? _speakerClient;

  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;

  bool get _gatewayActive => _ref.read(gatewayTtsActiveProvider);

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
      if (_speaker != null) {
        await _speaker!.stop();
      }
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
    unawaited(WakelockPlus.enable());
    try {
      await _ensureSpeaker().play(
        text,
        onStart: _onStart,
        onComplete: _onComplete,
        onError: _onError,
      );
    } finally {
      _releaseWakelockIfIdle();
    }
  }

  @override
  Future<void> startStreamingTts() async {
    if (!_gatewayActive) {
      await super.startStreamingTts();
      return;
    }
    DebugLogger.log('stream-start-via-gateway', scope: 'gateway/chat-tts');
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

  /// Release the wake lock only when no voice call is in progress — the
  /// call session has its own enable/disable pair, and a stray disable
  /// from chat TTS would let the screen sleep mid-call.
  void _releaseWakelockIfIdle() {
    final callActive = _ref.read(chatVoiceModeControllerProvider).isActive;
    if (!callActive) {
      unawaited(WakelockPlus.disable());
    }
  }

  @override
  Future<void> stop() async {
    if (_speaker != null) {
      await _speaker!.stop();
      _onCancel?.call();
      _releaseWakelockIfIdle();
    }
    await super.stop();
  }

  @override
  Future<void> pause() async {
    if (_gatewayActive && _speaker != null) {
      await _speaker!.pause();
      _onPause?.call();
      _releaseWakelockIfIdle();
      return;
    }
    await super.pause();
  }

  @override
  Future<void> resume() async {
    if (_gatewayActive && _speaker != null) {
      _onContinue?.call();
      unawaited(WakelockPlus.enable());
      try {
        await _speaker!.resume();
      } finally {
        _releaseWakelockIfIdle();
      }
      return;
    }
    await super.resume();
  }

  Future<void> seek(Duration position) async {
    if (!_gatewayActive) return;
    await _speaker?.seek(position);
  }

  Future<void> restart(String text) async {
    if (!_gatewayActive) {
      await super.speak(text);
      return;
    }
    unawaited(WakelockPlus.enable());
    try {
      await _ensureSpeaker().restart(
        text,
        onStart: _onStart,
        onComplete: _onComplete,
        onError: _onError,
      );
    } finally {
      _releaseWakelockIfIdle();
    }
  }

  Future<Duration?> storedPositionFor(String text) async {
    if (!_gatewayActive) return null;
    return _ensureSpeaker().storedPositionFor(text);
  }

  Duration get gatewayPosition => _speaker?.position ?? Duration.zero;

  bool get gatewayPaused => _speaker?.isPaused ?? false;

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
    await _speaker?.dispose();
    _speaker = null;
    await super.dispose();
  }
}

/// Use this in main.dart to override `textToSpeechServiceProvider`. Mirrors
/// upstream's provider shape (api watch + backend-config refresh listener)
/// so behavior is identical when the gateway is off.
TextToSpeechService createGatewayTextToSpeechService(Ref ref) {
  final api = ref.watch(apiServiceProvider);
  BackendConfig? readBackendConfig() {
    return ref
        .read(backendConfigProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
  }

  final service = GatewayTextToSpeechService(
    ref: ref,
    api: api,
    backendConfig: readBackendConfig(),
    loadBackendConfig: () async {
      await ref.read(backendConfigProvider.notifier).refresh();
      return readBackendConfig();
    },
  );
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
