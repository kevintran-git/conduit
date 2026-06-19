import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../core/utils/debug_logger.dart';

/// Plays a stream of raw PCM chunks through [FlutterPcmSound].
///
/// Each call to [stream] pumps a fresh frame stream through the speaker and
/// resolves when both conditions are direct observations:
///
///   1. The frame stream has closed (upstream said done)
///   2. The platform PCM buffer has emptied (everything fed has played)
///
/// No fixed timeouts and no decoder layer — bytes go from upstream to the
/// speaker hardware. Cancel mid-stream via [stop]; the native engine is
/// released to immediately silence any audio already queued in the platform
/// buffer (flutter_pcm_sound has no pause/stop primitive — release is the
/// only way to actually cut a playing buffer). The engine re-initializes
/// lazily on the next [stream] call.
///
/// Configure audio routing (iOS category, Android usage) through the
/// constructor — call surface needs `playAndRecord` for mic coexistence,
/// tap-to-speak just needs `playback`.
class PcmStreamSpeaker {
  PcmStreamSpeaker({
    this.sampleRateHz = 24000,
    this.iosAudioCategory = IosAudioCategory.playback,
    this.logScope = 'pcm-speaker',
  });

  final int sampleRateHz;
  final IosAudioCategory iosAudioCategory;
  final String logScope;

  bool _disposed = false;
  bool _engineUp = false;

  StreamSubscription<Uint8List>? _framesSub;
  Completer<void>? _drainCompleter;
  bool _framesDone = false;
  bool _audioStarted = false;
  int _frameCount = 0;
  int _byteCount = 0;
  Object? _pendingError;
  StackTrace? _pendingErrorStack;

  int get frameCount => _frameCount;
  int get byteCount => _byteCount;

  /// Pump [frames] through the speaker. Resolves when frames-done AND the
  /// platform buffer is empty. Throws if [frames] errors.
  ///
  /// [onFirstFrame] fires once when the first PCM chunk is fed (audio is
  /// now audible). [onProgress] fires on every chunk with cumulative counts.
  Future<void> stream(
    Stream<Uint8List> frames, {
    void Function()? onFirstFrame,
    void Function(int frameCount, int byteCount)? onProgress,
  }) async {
    if (_disposed) {
      throw StateError('PcmStreamSpeaker disposed');
    }
    // A new stream supersedes any in-flight one (barge-in semantics).
    await stop();
    await _ensureEngineUp();
    // dispose() may have landed during either await above; without this
    // re-check we'd register a fresh _drainCompleter against a released
    // engine — no feed callbacks ever fire, the caller awaits forever.
    if (_disposed) {
      throw StateError('PcmStreamSpeaker disposed');
    }

    _drainCompleter = Completer<void>();
    _framesDone = false;
    _audioStarted = false;
    _frameCount = 0;
    _byteCount = 0;
    _pendingError = null;
    _pendingErrorStack = null;

    _framesSub = frames.listen(
      (chunk) {
        if (_disposed) return;
        _frameCount++;
        _byteCount += chunk.length;
        // Copy into a fresh ByteData so the platform side owns its bytes
        // independent of the upstream Uint8List lifetime.
        final bd = ByteData(chunk.length)
          ..buffer.asUint8List().setRange(0, chunk.length, chunk);
        FlutterPcmSound.feed(PcmArrayInt16(bytes: bd));
        if (!_audioStarted) {
          _audioStarted = true;
          onFirstFrame?.call();
        }
        onProgress?.call(_frameCount, _byteCount);
      },
      onError: (Object error, StackTrace stack) {
        DebugLogger.error(
          'frames-error',
          scope: logScope,
          error: error,
          stackTrace: stack,
        );
        _pendingError = error;
        _pendingErrorStack = stack;
        _resolveDrain();
      },
      onDone: () {
        _framesDone = true;
        DebugLogger.log(
          'frames-done',
          scope: logScope,
          data: {'frames': _frameCount, 'bytes': _byteCount},
        );
        // If audio never started, there's nothing to drain — resolve now.
        // Otherwise the next _onFeed(0) wakes us up.
        if (!_audioStarted) _resolveDrain();
      },
      cancelOnError: false,
    );

    await _drainCompleter!.future;
    final err = _pendingError;
    final errStack = _pendingErrorStack;
    if (err != null) {
      Error.throwWithStackTrace(err, errStack ?? StackTrace.current);
    }
  }

  /// Cancel the current stream.
  ///
  /// [hardFlush] = true (barge-in path) releases the native engine to
  /// immediately silence any audio still in the platform buffer. The engine
  /// re-initializes lazily on the next [stream] call.
  ///
  /// [hardFlush] = false (normal turn-transition path) keeps the engine up
  /// so the next turn can start without re-setup latency. Safe because the
  /// buffer is already drained when called after [awaitDrain].
  Future<void> stop({bool hardFlush = false}) async {
    await _framesSub?.cancel();
    _framesSub = null;
    _framesDone = false;
    _audioStarted = false;
    _resolveDrain();
    if (hardFlush) await _releaseEngine();
  }

  Future<void> _releaseEngine() async {
    if (!_engineUp) return;
    FlutterPcmSound.setFeedCallback(null);
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    _engineUp = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop(hardFlush: true);
  }

  Future<void> _ensureEngineUp() async {
    if (_engineUp) return;
    await FlutterPcmSound.setup(
      sampleRate: sampleRateHz,
      channelCount: 1,
      iosAudioCategory: iosAudioCategory,
    );
    // Threshold 0 → callback fires when the buffer transitions to empty.
    await FlutterPcmSound.setFeedThreshold(0);
    FlutterPcmSound.setFeedCallback(_onFeed);
    FlutterPcmSound.start();
    _engineUp = true;
  }

  void _onFeed(int remainingFrames) {
    if (_disposed) return;
    if (_framesDone && _audioStarted && remainingFrames == 0) {
      _audioStarted = false;
      _resolveDrain();
    }
  }

  void _resolveDrain() {
    final c = _drainCompleter;
    _drainCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }
}
