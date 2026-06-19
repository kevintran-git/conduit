import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/backend_config.dart';
import '../../core/providers/app_providers.dart';
import '../../core/utils/debug_logger.dart';
import '../../features/chat/services/text_to_speech_service.dart';
import '../../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../audio/gateway_elevenlabs_tts_client.dart';
import '../config/gateway_providers.dart';
import '../router/gateway_router_providers.dart';
import 'gateway_chat_tts_speaker.dart';

/// [TextToSpeechService] subclass that streams the chat-message speaker
/// button through the gateway's ElevenLabs WS when gateway TTS is active.
///
/// Lets the chat path benefit from first-byte playback (rather than waiting
/// for the full PCM blob like upstream's TtsManager). Falls through to the
/// parent implementation (TtsManager → device / OWUI server) whenever the
/// gateway is off, so existing behavior is preserved for non-gateway users.
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
  GatewayElevenLabsTtsClient? _speakerClient;

  // Mirror the parent's lifecycle callbacks so we can fire them ourselves
  // when streaming bypasses TtsManager. We still call super.bindHandlers so
  // the device/OWUI path keeps working unchanged.
  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;

  bool get _gatewayActive => _ref.read(gatewayTtsActiveProvider);

  GatewayChatTtsSpeaker _ensureSpeaker() {
    final liveClient = _ref.read(gatewayElevenLabsClientProvider);
    // Recreate the speaker whenever the underlying client provider rebuilds
    // (config change, voice change, base URL change). Without this, the
    // cached speaker keeps using the first-launch client forever.
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
      // User flipped the toggle off mid-play — silence the gateway speaker
      // before falling through to the device path so we don't get two
      // overlapping audio streams.
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
      // Surface a cancel event so the chat UI clears its speaking indicator.
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
      return;
    }
    await super.pause();
  }

  @override
  Future<void> resume() async {
    if (_gatewayActive && _speaker != null) {
      await _speaker!.resume();
      _onContinue?.call();
      return;
    }
    await super.resume();
  }

  @override
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_gatewayActive) return super.getAvailableVoices();
    // Gateway TTS uses a single configured voice. Surface it as the only
    // option so the OWUI voice picker doesn't list voices that have no
    // effect when gateway TTS is on.
    final cfg = _ref.read(gatewayConfigProvider);
    return [
      {
        'name': cfg.ttsVoice,
        'identifier': cfg.ttsVoice,
        'locale': 'en-US',
      },
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
