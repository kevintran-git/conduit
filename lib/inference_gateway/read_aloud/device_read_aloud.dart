import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'read_aloud_engine.dart';
import 'read_aloud_plan.dart';

class DeviceReadAloud {
  DeviceReadAloud({
    required this.plan,
    required Future<void> Function(String text) speak,
    required Future<void> Function() pause,
    required Future<void> Function() resume,
  }) : _speak = speak,
       _pauseSpeech = pause,
       _resumeSpeech = resume;

  static const double _msPerWeight = 62;

  final ReadAloudPlan plan;
  final Future<void> Function(String text) _speak;
  final Future<void> Function() _pauseSpeech;
  final Future<void> Function() _resumeSpeech;

  final ValueNotifier<ReadAloudSnapshot?> snapshot = ValueNotifier(null);

  int _basePart = 0;
  int _baseOffset = 0;
  int _part = 0;
  int _segment = 0;
  int _word = -1;
  ReadAloudStatus _status = ReadAloudStatus.loading;
  bool _closed = false;

  int get segment => _segment;
  int get chunkBase => _basePart;
  bool get isPaused => _status == ReadAloudStatus.paused;

  Future<void> start(int segment) async {
    final index = _audibleFrom(segment, 1) ?? _audibleFrom(segment, -1);
    if (index == null || _closed) return;
    final target = plan.segments[index];
    _basePart = target.partIndex;
    _baseOffset = target.start;
    _part = _basePart;
    _segment = index;
    _word = -1;
    _status = ReadAloudStatus.loading;
    _publish();
    final rest = [
      plan.parts[_basePart].substring(_baseOffset),
      ...plan.parts.skip(_basePart + 1),
    ].join(' ');
    await _speak(rest);
  }

  void onChunk(int index) {
    _part = math.min(_basePart + index, plan.parts.length - 1);
    final offset = _part == _basePart ? _baseOffset : 0;
    _segment = plan.segmentAtPartOffset(_part, offset);
    _word = -1;
    _status = ReadAloudStatus.playing;
    _publish();
  }

  void onWord(int start) {
    final offset = start + (_part == _basePart ? _baseOffset : 0);
    _segment = plan.segmentAtPartOffset(_part, offset);
    final words = plan.segments[_segment].words;
    var word = 0;
    for (var w = 0; w < words.length; w++) {
      if (words[w].start <= offset) word = w;
    }
    _word = word;
    _status = ReadAloudStatus.playing;
    _publish();
  }

  void onPaused() {
    _status = ReadAloudStatus.paused;
    _publish();
  }

  void onResumed() {
    _status = ReadAloudStatus.playing;
    _publish();
  }

  Future<void> togglePause() async {
    if (isPaused) {
      _status = ReadAloudStatus.playing;
      _publish();
      await _resumeSpeech();
    } else {
      onPaused();
      await _pauseSpeech();
    }
  }

  Future<void> seekTo(Duration target) async {
    var remaining = math.max(0, target.inMilliseconds);
    for (final s in plan.segments) {
      final ms = _segmentMs(s);
      if (ms == 0) continue;
      if (remaining < ms) {
        await start(s.index);
        return;
      }
      remaining -= ms;
    }
    final last = _audibleFrom(plan.segments.length - 1, -1);
    if (last != null) await start(last);
  }

  Future<void> skipBy(Duration delta) =>
      seekTo(Duration(milliseconds: _positionMs()) + delta);

  Future<void> skipSegments(int delta) async {
    if (delta == 0) return;
    var target = _segment;
    for (var step = 0; step < delta.abs(); step++) {
      final next = _audibleFrom(target + delta.sign, delta.sign);
      if (next == null) break;
      target = next;
    }
    if (target == _segment && delta > 0) return;
    await start(target);
  }

  void close() {
    _closed = true;
    snapshot.value = null;
  }

  int? _audibleFrom(int from, int direction) {
    for (var i = from; i >= 0 && i < plan.segments.length; i += direction) {
      if (!plan.segments[i].silent) return i;
    }
    return null;
  }

  int _segmentMs(PlanSegment s) =>
      s.silent ? 0 : (s.totalWeight * _msPerWeight).round();

  int _positionMs() {
    var before = 0;
    for (var i = 0; i < _segment; i++) {
      before += _segmentMs(plan.segments[i]);
    }
    final current = plan.segments[_segment];
    final within = _word < 0
        ? 0
        : current.msForWord(_word, _segmentMs(current));
    return before + within;
  }

  void _publish() {
    if (_closed) return;
    var total = 0;
    for (final s in plan.segments) {
      total += _segmentMs(s);
    }
    snapshot.value = ReadAloudSnapshot(
      plan: plan,
      status: _status,
      buffering: false,
      retrying: false,
      stalled: false,
      segment: _segment,
      word: _word,
      position: Duration(milliseconds: _positionMs()),
      duration: Duration(milliseconds: total),
      durationExact: false,
      failed: const {},
      device: true,
    );
  }
}
