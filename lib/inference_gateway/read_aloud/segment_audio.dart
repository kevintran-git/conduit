import 'dart:async';
import 'dart:typed_data';

import 'package:inference_kit/inference_kit.dart' as ik;

import 'package:conduit_core/utils/debug_logger.dart';

import 'audio_shaper.dart';

abstract class SegmentAudio {
  int get length;
  bool get done;
  bool get failed;
  Uint8List bytesFrom(int start, int end);
  Future<void> waitForChange();
}

class CachedSegmentAudio implements SegmentAudio {
  CachedSegmentAudio(this._bytes);

  final Uint8List _bytes;

  @override
  int get length => _bytes.length;
  @override
  bool get done => true;
  @override
  bool get failed => false;

  @override
  Uint8List bytesFrom(int start, int end) =>
      Uint8List.sublistView(_bytes, start, end);

  @override
  Future<void> waitForChange() => Future<void>.value();
}

class SegmentJob implements SegmentAudio {
  SegmentJob({
    required this.client,
    required this.voice,
    required this.model,
    required this.text,
    required this.shaperFactory,
    this.maxAttempts = 3,
    this.firstFrameTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 6),
  });

  final ik.ElevenLabsTtsClient client;
  final String voice;
  final String model;
  final String text;
  final SegmentShaper Function() shaperFactory;
  final int maxAttempts;
  final Duration firstFrameTimeout;
  final Duration idleTimeout;

  Uint8List _buffer = Uint8List(64 * 1024);
  int _length = 0;
  bool _done = false;
  bool _failed = false;
  bool _complete = false;
  bool _cancelled = false;
  double? _measuredGain;
  ik.ElevenLabsTtsSession? _session;
  Completer<void> _change = Completer<void>();
  Future<void>? _run;

  @override
  int get length => _length;
  @override
  bool get done => _done;
  @override
  bool get failed => _failed;
  bool get complete => _complete;
  double? get measuredGain => _measuredGain;
  Future<void> get finished => _run ?? Future<void>.value();

  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, _length);

  @override
  Uint8List bytesFrom(int start, int end) =>
      Uint8List.fromList(Uint8List.sublistView(_buffer, start, end));

  @override
  Future<void> waitForChange() {
    if (_done) return Future<void>.value();
    return _change.future;
  }

  void _notify() {
    final change = _change;
    _change = Completer<void>();
    if (!change.isCompleted) change.complete();
  }

  void _append(Uint8List chunk) {
    if (chunk.isEmpty) return;
    final needed = _length + chunk.length;
    if (needed > _buffer.length) {
      var capacity = _buffer.length * 2;
      while (capacity < needed) {
        capacity *= 2;
      }
      _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
    }
    _buffer.setRange(_length, needed, chunk);
    _length = needed;
    _notify();
  }

  Future<void> start() => _run ??= _runAttempts();

  Future<void> _runAttempts() async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_cancelled) break;
      final outcome = await _attempt();
      if (outcome == _Outcome.complete) {
        _complete = true;
        break;
      }
      if (outcome == _Outcome.truncated || _cancelled) break;
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
    _failed = _length == 0;
    _done = true;
    _notify();
  }

  Future<_Outcome> _attempt() async {
    final shaper = shaperFactory();
    var received = 0;
    try {
      final session = await client.openSession(voice: voice, model: model);
      if (_cancelled) {
        await session.dispose();
        return _Outcome.failed;
      }
      _session = session;
      final ended = Completer<bool>();
      Timer? watchdog;
      void arm(Duration timeout) {
        watchdog?.cancel();
        watchdog = Timer(timeout, () {
          if (!ended.isCompleted) ended.complete(false);
        });
      }

      arm(firstFrameTimeout);
      final sub = session.frames.listen(
        (frame) {
          received += frame.length;
          _append(shaper.add(frame));
          arm(idleTimeout);
        },
        onError: (Object error, StackTrace stackTrace) {
          DebugLogger.error(
            'segment-frames-failed',
            scope: 'gateway/read-aloud',
            error: error,
            stackTrace: stackTrace,
          );
          if (!ended.isCompleted) ended.complete(false);
        },
        onDone: () {
          if (!ended.isCompleted) ended.complete(true);
        },
        cancelOnError: true,
      );
      session.appendText(text, triggerGeneration: true);
      session.flush();
      final finishedCleanly = await ended.future;
      watchdog?.cancel();
      await sub.cancel();
      await session.dispose();
      _session = null;
      if (_cancelled) return _Outcome.failed;
      if (received == 0) return _Outcome.failed;
      _append(shaper.finish());
      _measuredGain = shaper.measuredGain;
      if (!finishedCleanly) {
        DebugLogger.log(
          'segment-ended-without-final',
          scope: 'gateway/read-aloud',
          data: {'bytes': received},
        );
      }
      return finishedCleanly ? _Outcome.complete : _Outcome.truncated;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'segment-synthesis-failed',
        scope: 'gateway/read-aloud',
        error: error,
        stackTrace: stackTrace,
      );
      await _session?.dispose();
      _session = null;
      return received > 0 ? _Outcome.truncated : _Outcome.failed;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _session?.dispose();
    _session = null;
    if (!_done && _run == null) {
      _done = true;
      _failed = _length == 0;
      _notify();
    }
  }
}

enum _Outcome { complete, truncated, failed }
