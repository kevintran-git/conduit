import 'dart:async';

import '../../core/utils/debug_logger.dart';
import '../audio/gateway_elevenlabs_tts_client.dart';
import '../audio/pcm_stream_speaker.dart';
import '../config/gateway_config.dart';

/// One-shot streaming TTS for the chat-message speaker button.
///
/// Opens an ElevenLabs WS, pushes the full text + flush, and pumps PCM
/// frames through a [PcmStreamSpeaker]. `play(text)` resolves when audio
/// finishes (or errors). Fires lifecycle callbacks so the upstream
/// `TextToSpeechController` can update its "Speaking…" indicator without
/// us having to touch its event bus.
class GatewayChatTtsSpeaker {
  GatewayChatTtsSpeaker({
    required GatewayElevenLabsTtsClient client,
    required this.config,
  })  : _client = client,
        _speaker = PcmStreamSpeaker(logScope: 'gateway/chat-tts');

  final GatewayElevenLabsTtsClient _client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;

  bool _disposed = false;
  ElevenLabsTtsSession? _session;

  Future<void> play(
    String text, {
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
    String? voiceOverride,
  }) async {
    if (_disposed) return;
    if (text.trim().isEmpty) {
      onComplete?.call();
      return;
    }
    await stop();

    try {
      DebugLogger.log('open-session', scope: 'gateway/chat-tts', data: {
        'voice': voiceOverride ?? config.ttsVoice,
        'model': config.ttsModel,
        'text_len': text.length,
      });
      final session = await _client.openSession(
        voice: voiceOverride ?? config.ttsVoice,
        model: config.ttsModel,
      );
      _session = session;
      session.appendText(text, triggerGeneration: true);
      session.flush();
      await _speaker.stream(session.frames, onFirstFrame: onStart);
      onComplete?.call();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'play-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      onError?.call(error.toString());
    } finally {
      await _session?.dispose();
      _session = null;
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    // hardFlush so user-initiated stop silences audio immediately.
    await _speaker.stop(hardFlush: true);
    await _session?.dispose();
    _session = null;
  }

  /// FlutterPcmSound has no pause/resume; tap-to-speak doesn't need it.
  /// Kept as no-ops to preserve the existing API.
  Future<void> pause() async {}
  Future<void> resume() async {}

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _speaker.dispose();
  }
}
