import 'dart:async';

import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../config/gateway_config.dart';
import 'chat_tts_background_lease.dart';

class GatewayChatTtsSpeaker {
  GatewayChatTtsSpeaker({
    required ik.ElevenLabsTtsClient client,
    required this.config,
    ChatTtsBackgroundLease? backgroundLease,
  }) : _client = client,
       _speaker = PcmStreamSpeaker(logScope: 'gateway/chat-tts'),
       _lease = backgroundLease ?? ChatTtsBackgroundLease();

  final ik.ElevenLabsTtsClient _client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;
  final ChatTtsBackgroundLease _lease;

  bool _disposed = false;
  ik.ElevenLabsTtsSession? _session;
  Future<void>? _playback;
  int _fedLength = 0;
  void Function()? _streamOnComplete;
  void Function(String message)? _streamOnError;

  bool get isStreaming => _session != null;

  Future<void> startStream({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
  }) async {
    if (_disposed) return;
    await stop();
    _fedLength = 0;
    _streamOnComplete = onComplete;
    _streamOnError = onError;
    await _lease.acquire();

    try {
      DebugLogger.log(
        'open-session',
        scope: 'gateway/chat-tts',
        data: {'voice': config.ttsVoice, 'model': config.ttsModel},
      );
      final session = await _client.openSession(
        voice: config.ttsVoice,
        model: config.ttsModel,
      );
      _session = session;
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
      await _lease.release();
      onError?.call(error.toString());
    }
  }

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
      await _lease.release();
      await _session?.dispose();
      _session = null;
    }
  }

  Future<void> stop() async {
    _playback = null;
    _fedLength = 0;
    _streamOnComplete = null;
    _streamOnError = null;
    await _speaker.stop(hardFlush: true);
    await _session?.dispose();
    _session = null;
    await _lease.release();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _speaker.dispose();
  }
}
