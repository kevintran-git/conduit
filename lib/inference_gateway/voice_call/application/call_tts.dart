import 'dart:async';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../../core/utils/debug_logger.dart';
import '../../audio/gateway_elevenlabs_tts_client.dart';
import '../../audio/pcm_stream_speaker.dart';
import '../../config/gateway_config.dart';

/// Coarse pipeline state for [CallTts]. Surfaced via [CallTts.status] so
/// the UI can render "what's the TTS doing right now."
enum TtsStage {
  idle,
  connecting,
  waiting,
  playing,
  drained,
  stopped,
  error,
}

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

/// Streaming TTS for the call surface. One [ElevenLabsTtsSession] per turn;
/// PCM frames are pumped through a shared [PcmStreamSpeaker]. No HTTP
/// proxy, no WAV header trickery, no decoder layer, no timeouts.
class CallTts {
  CallTts({required this.client, required this.config})
      : _speaker = PcmStreamSpeaker(
          // Call mode: mic stays open / reopens between turns, so we need
          // an audio category that coexists with capture.
          iosAudioCategory: IosAudioCategory.playAndRecord,
          logScope: 'call/tts',
        );

  final GatewayElevenLabsTtsClient client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;

  /// Speaker hardware-flush pad before the mic reopens. Without it the mic
  /// catches the tail of the speaker on iOS/Android.
  static const Duration _speakerDrainDelay = Duration(milliseconds: 250);

  bool _disposed = false;
  bool _stopping = false;

  ElevenLabsTtsSession? _session;
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

  /// Open a fresh WS session. Fire-and-forget — text appended before the
  /// handshake completes is buffered and drained after the WS opens.
  Future<void> open() {
    if (_disposed) return Future.value();
    return _openInFlight ??= _doOpen();
  }

  Future<void> _doOpen() async {
    // Close the previous turn without hard-flushing — buffer is already
    // drained, and re-setup would add startup latency on the next turn.
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
      // Caller-initiated stop()/dispose() may have landed while the WS
      // handshake was in flight. Without this re-check the freshly opened
      // session would reassign _session and start playing audio AFTER the
      // user had explicitly silenced it.
      if (_disposed || _stopping) {
        await session.dispose();
        return;
      }
      _session = session;
      _setStage(TtsStage.waiting);

      // Kick off PCM streaming. [awaitDrain] awaits this; we don't await
      // here so [append] / [flush] can pump text in concurrently.
      _streamFuture = _speaker.stream(
        session.frames,
        onFirstFrame: () {
          _emitPlaying(true);
          _setStage(TtsStage.playing);
        },
        onProgress: (frames, bytes) {
          // Throttle UI updates: every ~5 frames is plenty.
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

  /// Pipe a token in. Buffered if the WS is still opening.
  void append(String text) {
    if (_disposed || text.isEmpty) return;
    final session = _session;
    if (session == null) {
      _pendingText.write(text);
      return;
    }
    session.appendText(text, triggerGeneration: true);
  }

  /// Tell the server we're done emitting text. Deferred if the WS is still
  /// opening so it fires right after buffered text is flushed through.
  void flush() {
    if (_disposed) return;
    final session = _session;
    if (session == null) {
      _pendingFlush = true;
      return;
    }
    session.flush();
  }

  /// Resolves when the current response's audio has fully drained — server
  /// closed AND platform buffer empty. Adds a 250ms speaker-flush pad so
  /// the mic can reopen without acoustic feedback.
  ///
  /// If [open] is still running, awaits it first so we don't no-op past a
  /// slow handshake. If the open failed (no _streamFuture), throws the
  /// captured open error so the caller surfaces a visible failure instead
  /// of silently returning and reopening the mic to silence.
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
    if (_status.stage != TtsStage.stopped &&
        _status.stage != TtsStage.error) {
      _setStage(TtsStage.drained);
    }
    _emitPlaying(false);
    if (_disposed) return;
    await Future.delayed(_speakerDrainDelay);
  }

  /// Cancel the in-flight response (barge-in or hangup). Hard-flushes the
  /// native audio buffer so playback stops *now* — flutter_pcm_sound has no
  /// pause primitive, so we have to release/re-setup the engine to actually
  /// cut a buffered tail. Next [open] will re-setup it lazily.
  Future<void> stop() async {
    if (_disposed) return;
    _stopping = true;
    _pendingText.clear();
    _pendingFlush = false;
    try {
      // If a handshake is still in-flight, wait for it so its `if (_stopping)`
      // re-check observes the flag and disposes the freshly-opened session
      // instead of plugging it into the speaker.
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

  /// Shared session/stream/playing cleanup. Caller decides whether to
  /// hard-flush the speaker (true = barge-in / hangup, where we need
  /// playback to cut now; false = next-turn handoff, where keeping the
  /// engine warm saves ~tens of ms of setup latency).
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
    // Detach immediately so the caller (e.g. CallSession._teardown) returns
    // synchronously — the native PCM engine release and any in-flight WS
    // handshake can take seconds, and blocking the dispose path on them
    // causes Android ANRs when the user taps End. Fire-and-forget cleanup:
    // _disposed gates the open() retry, so a late-arriving session disposes
    // itself.
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

  void _setStage(TtsStage stage, {String? errorMessage, int? frames, int? bytes}) {
    _status = TtsStatus(
      stage: stage,
      frames: frames ?? _status.frames,
      bytes: bytes ?? _status.bytes,
      errorMessage: errorMessage,
    );
    if (!_statusController.isClosed) _statusController.add(_status);
  }
}
