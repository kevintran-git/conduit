class FedSpan {
  FedSpan({
    required this.runStart,
    required this.segment,
    required this.segmentOffset,
    required this.length,
  });

  final int runStart;
  final int segment;
  final int segmentOffset;
  int length;
}

class PlaybackClock {
  PlaybackClock({required this.bytesPerSecond, Duration Function()? now})
    : _now = now ?? _stopwatchNow();

  final int bytesPerSecond;
  final Duration Function() _now;

  final List<FedSpan> spans = <FedSpan>[];
  int _fed = 0;
  int? _anchorBytes;
  Duration? _anchorTime;

  static Duration Function() _stopwatchNow() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  int get fedBytes => _fed;
  bool get started => _anchorBytes != null;

  void start() {
    if (started) return;
    _anchorBytes = 0;
    _anchorTime = _now();
  }

  int _rawPlayed() {
    final anchorBytes = _anchorBytes;
    final anchorTime = _anchorTime;
    if (anchorBytes == null || anchorTime == null) return 0;
    final elapsed = _now() - anchorTime;
    final raw =
        anchorBytes + elapsed.inMicroseconds * bytesPerSecond ~/ 1000000;
    return raw - raw % 2;
  }

  int get playedBytes {
    final raw = _rawPlayed();
    return raw < _fed ? raw : _fed;
  }

  bool get starved => started && _rawPlayed() >= _fed;

  int get bufferedBytes => _fed - playedBytes;

  void fed(int segment, int segmentOffset, int length) {
    if (length <= 0) return;
    if (starved) {
      _anchorBytes = _fed;
      _anchorTime = _now();
    }
    final last = spans.isEmpty ? null : spans.last;
    if (last != null &&
        last.segment == segment &&
        last.segmentOffset + last.length == segmentOffset &&
        last.runStart + last.length == _fed) {
      last.length += length;
    } else {
      spans.add(
        FedSpan(
          runStart: _fed,
          segment: segment,
          segmentOffset: segmentOffset,
          length: length,
        ),
      );
    }
    _fed += length;
  }

  ({int segment, int offset})? positionAt(int played) {
    if (spans.isEmpty) return null;
    for (var i = spans.length - 1; i >= 0; i--) {
      final span = spans[i];
      if (span.runStart <= played) {
        final within = played - span.runStart;
        final clamped = within > span.length ? span.length : within;
        return (segment: span.segment, offset: span.segmentOffset + clamped);
      }
    }
    final first = spans.first;
    return (segment: first.segment, offset: first.segmentOffset);
  }

  ({int segment, int offset})? get position => positionAt(playedBytes);
}
