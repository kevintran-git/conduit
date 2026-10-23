import 'dart:math' as math;
import 'dart:typed_data';

class TimeStretcher {
  TimeStretcher({required this.speed, int sampleRate = 24000})
    : _window = (sampleRate * 0.03).round() & ~1,
      _tolerance = (sampleRate * 0.008).round() {
    _hop = _window ~/ 2;
    _taper = Float64List(_window);
    for (var i = 0; i < _window; i++) {
      _taper[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / _window);
    }
    _overlap = Float64List(_window);
  }

  final double speed;
  final int _window;
  final int _tolerance;
  late final int _hop;
  late final Float64List _taper;
  late Float64List _overlap;

  Float64List _input = Float64List(0);
  int _inputBase = 0;
  double _nominal = 0;
  int? _previous;

  bool get passthrough => (speed - 1).abs() < 0.01;

  Uint8List process(Uint8List pcm) {
    if (passthrough) return pcm;
    _append(pcm);
    final out = <double>[];
    while (true) {
      final position = _nextPosition();
      if (position == null) break;
      _emitFrame(position, out);
    }
    _trim();
    return _encode(out);
  }

  Uint8List flush() {
    if (passthrough) return Uint8List(0);
    final out = <double>[for (var i = 0; i < _hop; i++) _overlap[i]];
    _overlap = Float64List(_window);
    _input = Float64List(0);
    _inputBase = 0;
    _nominal = 0;
    _previous = null;
    return _encode(out);
  }

  void _append(Uint8List pcm) {
    final view = ByteData.sublistView(pcm);
    final count = pcm.length ~/ 2;
    final next = Float64List(_input.length + count);
    next.setRange(0, _input.length, _input);
    for (var i = 0; i < count; i++) {
      next[_input.length + i] = view.getInt16(i * 2, Endian.little).toDouble();
    }
    _input = next;
  }

  int? _nextPosition() {
    final end = _inputBase + _input.length;
    final previous = _previous;
    if (previous == null) {
      return end >= _window ? 0 : null;
    }
    final center = _nominal.round();
    final lowest = math.max(previous + 1, center - _tolerance);
    final highest = center + _tolerance;
    final natural = previous + _hop;
    if (highest + _window > end || natural + _window > end) return null;
    var best = math.max(lowest, center);
    var bestScore = double.negativeInfinity;
    for (var candidate = lowest; candidate <= highest; candidate += 2) {
      var score = 0.0;
      for (var j = 0; j < _window; j += 4) {
        score += _sample(natural + j) * _sample(candidate + j);
      }
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  double _sample(int absolute) => _input[absolute - _inputBase];

  void _emitFrame(int position, List<double> out) {
    for (var i = 0; i < _window; i++) {
      _overlap[i] += _sample(position + i) * _taper[i];
    }
    for (var i = 0; i < _hop; i++) {
      out.add(_overlap[i]);
    }
    final shifted = Float64List(_window);
    shifted.setRange(0, _window - _hop, _overlap, _hop);
    _overlap = shifted;
    _previous = position;
    _nominal += _hop * speed;
  }

  void _trim() {
    final previous = _previous;
    if (previous == null) return;
    final keep = math.min(previous + 1, _nominal.round() - _tolerance);
    final drop = (keep - _inputBase).clamp(0, _input.length);
    if (drop == 0) return;
    _input = Float64List.fromList(Float64List.sublistView(_input, drop));
    _inputBase += drop;
  }

  static Uint8List _encode(List<double> samples) {
    final bytes = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      final v = samples[i].round().clamp(-32768, 32767);
      view.setInt16(i * 2, v, Endian.little);
    }
    return bytes;
  }
}
