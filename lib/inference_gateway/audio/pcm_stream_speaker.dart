import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../core/utils/debug_logger.dart';

abstract class PcmAudioSink {
  Future<void> setup({required int sampleRateHz, required int numChannels});
  Future<void> feed(Uint8List bytes);
  Future<void> setFeedThreshold(int threshold);
  void setFeedCallback(void Function(int remainingFrames)? callback);
  bool start();
  Future<void> release();
}

class FlutterPcmSoundSink implements PcmAudioSink {
  FlutterPcmSoundSink({this.iosAudioCategory = IosAudioCategory.playback});

  final IosAudioCategory iosAudioCategory;

  @override
  Future<void> setup({required int sampleRateHz, required int numChannels}) {
    return FlutterPcmSound.setup(
      sampleRate: sampleRateHz,
      channelCount: numChannels,
      iosAudioCategory: iosAudioCategory,
    );
  }

  @override
  Future<void> feed(Uint8List bytes) {
    final bd = ByteData(bytes.length)
      ..buffer.asUint8List().setRange(0, bytes.length, bytes);
    return FlutterPcmSound.feed(PcmArrayInt16(bytes: bd));
  }

  @override
  Future<void> setFeedThreshold(int threshold) {
    return FlutterPcmSound.setFeedThreshold(threshold);
  }

  @override
  void setFeedCallback(void Function(int remainingFrames)? callback) {
    FlutterPcmSound.setFeedCallback(callback);
  }

  @override
  bool start() => FlutterPcmSound.start();

  @override
  Future<void> release() => FlutterPcmSound.release();
}

/// Plays a stream of raw PCM chunks through an injected [PcmAudioSink].
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
/// buffer (the sink has no pause/stop primitive — release is the only way to
/// actually cut a playing buffer). The engine re-initializes lazily on the
/// next [stream] call.
///
/// Defaults to [FlutterPcmSoundSink]. Pass [sink] to swap in a different
/// backend (e.g. a native voice-call AudioTrack on Android) while keeping the
/// jitter-buffer/drain-detection logic below unchanged.
class PcmStreamSpeaker {
  PcmStreamSpeaker({
    this.sampleRateHz = 24000,
    this.iosAudioCategory = IosAudioCategory.playback,
    this.logScope = 'pcm-speaker',
    this.jitterBufferMs = 200,
    PcmAudioSink? sink,
  }) : _sink = sink ?? FlutterPcmSoundSink(iosAudioCategory: iosAudioCategory);

  final int sampleRateHz;
  final IosAudioCategory iosAudioCategory;
  final String logScope;
  final int jitterBufferMs;
  final PcmAudioSink _sink;

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
  final BytesBuilder _primeBuffer = BytesBuilder(copy: false);
  bool _primed = false;
  void Function()? _onFirstFrame;

  int get _jitterBufferBytes => sampleRateHz * 2 * jitterBufferMs ~/ 1000;

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
    await stop();
    await _ensureEngineUp();
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
    _onFirstFrame = onFirstFrame;

    _framesSub = frames.listen(
      (chunk) {
        if (_disposed) return;
        _frameCount++;
        _byteCount += chunk.length;
        _ingest(chunk);
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
        _flushPrimeBuffer();
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

  void _ingest(Uint8List chunk) {
    if (_primed) {
      _feed(chunk);
      return;
    }
    _primeBuffer.add(chunk);
    if (_primeBuffer.length < _jitterBufferBytes) return;
    _primed = true;
    _feed(_primeBuffer.takeBytes());
  }

  void _flushPrimeBuffer() {
    if (_primed) return;
    _primed = true;
    if (_primeBuffer.isEmpty) return;
    _feed(_primeBuffer.takeBytes());
  }

  void _feed(Uint8List bytes) {
    unawaited(_sink.feed(bytes));
    if (!_audioStarted) {
      _audioStarted = true;
      _onFirstFrame?.call();
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
    _primed = false;
    _primeBuffer.clear();
    _resolveDrain();
    if (hardFlush) await _releaseEngine();
  }

  Future<void> _releaseEngine() async {
    if (!_engineUp) return;
    _sink.setFeedCallback(null);
    try {
      await _sink.release();
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
    await _sink.setup(sampleRateHz: sampleRateHz, numChannels: 1);
    await _sink.setFeedThreshold(0);
    _sink.setFeedCallback(_onFeed);
    _sink.start();
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
