import 'dart:async';

import 'package:pcm_call_audio/pcm_call_audio.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

import 'package:conduit_core/utils/debug_logger.dart';

import '../../config/gateway_config.dart';

enum TtsStage { idle, connecting, waiting, playing, drained, stopped, error }

class TtsStatus {
  const TtsStatus({
    required this.stage,
    this.frames = 0,
    this.bytes = 0,
    this.errorMessage,
  });

  final TtsStage stage;
  final int frames;
  final int bytes;
  final String? errorMessage;

  static const TtsStatus idle = TtsStatus(stage: TtsStage.idle);

  String get label {
    switch (stage) {
      case TtsStage.idle:
        return 'idle';
      case TtsStage.connecting:
        return 'opening voice…';
      case TtsStage.waiting:
        return 'waiting for audio…';
      case TtsStage.playing:
        return 'playing • $frames frames • ${_kb(bytes)} KB';
      case TtsStage.drained:
        return 'drained • $frames frames • ${_kb(bytes)} KB';
      case TtsStage.stopped:
        return 'stopped';
      case TtsStage.error:
        return 'failed${errorMessage == null ? '' : ': $errorMessage'}';
    }
  }

  static String _kb(int bytes) {
    if (bytes < 1024) return bytes.toString();
    return (bytes / 1024).toStringAsFixed(1);
  }
}

class CallTts {
  CallTts({
    required this.client,
    required this.config,
    PcmStreamSpeaker? speaker,
  }) : _speaker =
           speaker ??
           PcmStreamSpeaker(
             iosAudioCategory: IosAudioCategory.playAndRecord,
             logScope: 'call/tts',
           );

  final ik.ElevenLabsTtsClient client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;

  static const Duration _speakerDrainDelay = Duration(milliseconds: 250);

  bool _disposed = false;
  bool _stopping = false;

  ik.ElevenLabsTtsSession? _session;
  Future<void>? _streamFuture;
  Future<void>? _openInFlight;
  Object? _openError;
  final StringBuffer _pendingText = StringBuffer();
  bool _pendingFlush = false;

  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  bool _lastPlaying = false;

  final StreamController<TtsStatus> _statusController =
      StreamController<TtsStatus>.broadcast();
  TtsStatus _status = TtsStatus.idle;

  TtsStatus get status => _status;
  Stream<TtsStatus> get statusStream => _statusController.stream;
  Stream<bool> get playing => _playingController.stream;

  Future<void> open() {
    if (_disposed) return Future.value();
    return _openInFlight ??= _doOpen();
  }

  Future<void> _doOpen() async {
    if (_session != null) await _close(hardFlush: false);
    _pendingText.clear();
    _pendingFlush = false;
    _openError = null;
    _setStage(TtsStage.connecting);

    try {
      DebugLogger.log(
        'open',
        scope: 'call/tts',
        data: {'voice': config.ttsVoice, 'model': config.ttsModel},
      );
      final session = await client.openSession(
        voice: config.ttsVoice,
        model: config.ttsModel,
      );
      if (_disposed || _stopping) {
        await session.dispose();
        return;
      }
      _session = session;
      _setStage(TtsStage.waiting);

      _streamFuture = _speaker.stream(
        session.frames,
        onFirstFrame: () {
          _emitPlaying(true);
          _setStage(TtsStage.playing);
        },
        onProgress: (frames, bytes) {
          if (frames % 5 == 0) {
            _setStage(TtsStage.playing, frames: frames, bytes: bytes);
          }
        },
      );

      if (_pendingText.isNotEmpty) {
        session.appendText(_pendingText.toString(), triggerGeneration: true);
        _pendingText.clear();
      }
      if (_pendingFlush) {
        _pendingFlush = false;
        session.flush();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'open-failed',
        scope: 'call/tts',
        error: error,
        stackTrace: stackTrace,
      );
      await _session?.dispose();
      _session = null;
      _openError = error;
      _setStage(TtsStage.error, errorMessage: error.toString());
    } finally {
      _openInFlight = null;
    }
  }

  void append(String text) {
    if (_disposed || text.isEmpty) return;
    final session = _session;
    if (session == null) {
      _pendingText.write(text);
      return;
    }
    session.appendText(text, triggerGeneration: true);
  }

  void flush() {
    if (_disposed) return;
    final session = _session;
    if (session == null) {
      _pendingFlush = true;
      return;
    }
    session.flush();
  }

  Future<void> awaitDrain() async {
    final pendingOpen = _openInFlight;
    if (pendingOpen != null) {
      try {
        await pendingOpen;
      } catch (_) {}
    }
    final f = _streamFuture;
    if (f == null) {
      final err = _openError;
      if (err != null) {
        throw StateError('TTS open failed: $err');
      }
      return;
    }
    try {
      await f;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'drain-error',
        scope: 'call/tts',
        error: error,
        stackTrace: stackTrace,
      );
      _setStage(TtsStage.error, errorMessage: error.toString());
    }
    if (_status.stage != TtsStage.stopped && _status.stage != TtsStage.error) {
      _setStage(TtsStage.drained);
    }
    _emitPlaying(false);
    if (_disposed) return;
    await Future.delayed(_speakerDrainDelay);
  }

  Future<void> stop() async {
    if (_disposed) return;
    _stopping = true;
    _pendingText.clear();
    _pendingFlush = false;
    try {
      final pendingOpen = _openInFlight;
      if (pendingOpen != null) {
        try {
          await pendingOpen;
        } catch (_) {}
      }
      await _close(hardFlush: true);
      if (_status.stage != TtsStage.idle && _status.stage != TtsStage.drained) {
        _setStage(TtsStage.stopped);
      }
    } finally {
      _stopping = false;
    }
  }

  Future<void> _close({required bool hardFlush}) async {
    await _speaker.stop(hardFlush: hardFlush);
    await _session?.dispose();
    _session = null;
    _streamFuture = null;
    _emitPlaying(false);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingText.clear();
    _pendingFlush = false;
    unawaited(() async {
      try {
        await _close(hardFlush: true);
      } catch (_) {}
      try {
        await _speaker.dispose();
      } catch (_) {}
      if (!_playingController.isClosed) {
        unawaited(_playingController.close());
      }
      if (!_statusController.isClosed) {
        unawaited(_statusController.close());
      }
    }());
  }

  void _emitPlaying(bool value) {
    if (value == _lastPlaying) return;
    _lastPlaying = value;
    if (!_playingController.isClosed) _playingController.add(value);
  }

  void _setStage(
    TtsStage stage, {
    String? errorMessage,
    int? frames,
    int? bytes,
  }) {
    _status = TtsStatus(
      stage: stage,
      frames: frames ?? _status.frames,
      bytes: bytes ?? _status.bytes,
      errorMessage: errorMessage,
    );
    if (!_statusController.isClosed) _statusController.add(_status);
  }
}
