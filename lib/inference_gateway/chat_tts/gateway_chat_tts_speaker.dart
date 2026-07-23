import 'dart:async';

import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart';

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';

/// Streaming TTS for the chat surface, in one-shot and incremental flavors.
///
/// Both open an ElevenLabs WS and pump PCM frames through a
/// [PcmStreamSpeaker], so playback starts on the first frame instead of
/// waiting for a full PCM blob. [play] pushes a complete string and resolves
/// when the audio finishes; [startStream]/[feed]/[finishStream] append text as
/// a reply arrives, which is what upstream's voice mode drives through
/// `TextToSpeechService.feedStreamingText`.
///
/// Lifecycle callbacks let upstream's `TextToSpeechController` update its
/// "Speaking…" indicator without us touching its event bus.
class GatewayChatTtsSpeaker {
  GatewayChatTtsSpeaker({
    required ik.ElevenLabsTtsClient client,
    required this.config,
  }) : _client = client,
       _speaker = PcmStreamSpeaker(logScope: 'gateway/chat-tts');

  final ik.ElevenLabsTtsClient _client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;

  bool _disposed = false;
  ik.ElevenLabsTtsSession? _session;

  Future<void>? _playback;
  int _fedLength = 0;
  void Function()? _streamOnComplete;
  void Function(String message)? _streamOnError;

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
      final session = await _openSession(
        voiceOverride,
        textLength: text.length,
      );
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

  /// Opens a session that stays open across [feed] calls. Playback runs in the
  /// background from here on; [finishStream] is what waits for it to drain.
  Future<void> startStream({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
    String? voiceOverride,
  }) async {
    if (_disposed) return;
    await stop();
    _fedLength = 0;
    _streamOnComplete = onComplete;
    _streamOnError = onError;

    try {
      final session = await _openSession(voiceOverride);
      _playback = _speaker
          .stream(session.frames, onFirstFrame: onStart)
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'stream-playback-failed',
              scope: 'gateway/chat-tts',
              error: error,
              stackTrace: stackTrace,
            );
            _streamOnError?.call(error.toString());
          });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'stream-open-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      onError?.call(error.toString());
    }
  }

  /// Appends whatever part of [accumulatedText] hasn't been sent yet. Callers
  /// pass the full text so far, matching `TextToSpeechService`'s contract.
  void feed(String accumulatedText) {
    final session = _session;
    if (_disposed || session == null) return;
    if (accumulatedText.length <= _fedLength) return;
    session.appendText(
      accumulatedText.substring(_fedLength),
      triggerGeneration: true,
    );
    _fedLength = accumulatedText.length;
  }

  /// Flushes the session and resolves once the queued audio has played out.
  Future<void> finishStream({String? finalText}) async {
    final session = _session;
    if (_disposed || session == null) return;
    if (finalText != null) feed(finalText);
    session.flush();
    try {
      await _playback;
      _streamOnComplete?.call();
    } finally {
      _playback = null;
      _streamOnComplete = null;
      _streamOnError = null;
      await _session?.dispose();
      _session = null;
    }
  }

  Future<ik.ElevenLabsTtsSession> _openSession(
    String? voiceOverride, {
    int? textLength,
  }) async {
    DebugLogger.log(
      'open-session',
      scope: 'gateway/chat-tts',
      data: {
        'voice': voiceOverride ?? config.ttsVoice,
        'model': config.ttsModel,
        'text_len': ?textLength,
      },
    );
    final session = await _client.openSession(
      voice: voiceOverride ?? config.ttsVoice,
      model: config.ttsModel,
    );
    _session = session;
    return session;
  }

  Future<void> stop() async {
    if (_disposed) return;
    _playback = null;
    _fedLength = 0;
    _streamOnComplete = null;
    _streamOnError = null;
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
