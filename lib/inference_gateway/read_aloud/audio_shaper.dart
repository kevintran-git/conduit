import 'dart:math' as math;
import 'dart:typed_data';

const int kShaperSilenceThreshold = 200;
const double kShaperTargetDbfs = -20;
const double kShaperMaxGainDb = 9;

double gainForRms(double rms) {
  if (rms < 1) return 1;
  final db = kShaperTargetDbfs - 20 * math.log(rms / 32768) / math.ln10;
  return math
      .pow(10, db.clamp(-kShaperMaxGainDb, kShaperMaxGainDb) / 20)
      .toDouble();
}

class SegmentShaper {
  SegmentShaper({
    required this.gain,
    required int sampleRate,
    int leadKeepMs = 120,
    int tailKeepMs = 300,
    int fadeMs = 8,
  }) : _leadKeep = leadKeepMs * sampleRate ~/ 1000,
       _tailKeep = tailKeepMs * sampleRate ~/ 1000,
       _fade = fadeMs * sampleRate ~/ 1000,
       _minMeasured = sampleRate ~/ 2;

  final double gain;
  final int _leadKeep;
  final int _tailKeep;
  final int _fade;
  final int _minMeasured;

  int? _pendingByte;
  bool _leadDone = false;
  final List<int> _held = <int>[];
  int _emitted = 0;
  double _sumSquares = 0;
  int _voiced = 0;

  double? get measuredGain {
    if (_voiced < _minMeasured) return null;
    return gainForRms(math.sqrt(_sumSquares / _voiced));
  }

  Uint8List add(Uint8List pcm) {
    final samples = _toSamples(pcm);
    if (samples.isEmpty) return Uint8List(0);
    final out = <int>[];
    var i = 0;
    if (!_leadDone) {
      while (i < samples.length && samples[i].abs() < kShaperSilenceThreshold) {
        _held.add(samples[i]);
        i++;
      }
      if (_held.length > _leadKeep) {
        _held.removeRange(0, _held.length - _leadKeep);
      }
      if (i == samples.length) return Uint8List(0);
      _leadDone = true;
    }
    var lastLoud = -1;
    for (var j = samples.length - 1; j >= i; j--) {
      if (samples[j].abs() >= kShaperSilenceThreshold) {
        lastLoud = j;
        break;
      }
    }
    if (lastLoud < 0) {
      for (var j = i; j < samples.length; j++) {
        _held.add(samples[j]);
      }
      return Uint8List(0);
    }
    out.addAll(_held);
    _held.clear();
    for (var j = i; j <= lastLoud; j++) {
      final s = samples[j];
      out.add(s);
      if (s.abs() >= kShaperSilenceThreshold) {
        _sumSquares += s * s.toDouble();
        _voiced++;
      }
    }
    for (var j = lastLoud + 1; j < samples.length; j++) {
      _held.add(samples[j]);
    }
    return _emit(out, fadeOut: false);
  }

  Uint8List finish() {
    if (!_leadDone) {
      _held.clear();
      return Uint8List(0);
    }
    final keep = math.min(_held.length, _tailKeep);
    final out = _held.sublist(0, keep);
    _held.clear();
    return _emit(out, fadeOut: true);
  }

  List<int> _toSamples(Uint8List pcm) {
    var bytes = pcm;
    final pending = _pendingByte;
    if (pending != null) {
      bytes = Uint8List(pcm.length + 1)
        ..[0] = pending
        ..setRange(1, pcm.length + 1, pcm);
      _pendingByte = null;
    }
    if (bytes.length.isOdd) {
      _pendingByte = bytes[bytes.length - 1];
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    final data = ByteData.sublistView(bytes);
    return [
      for (var k = 0; k < bytes.length ~/ 2; k++)
        data.getInt16(k * 2, Endian.little),
    ];
  }

  Uint8List _emit(List<int> samples, {required bool fadeOut}) {
    final out = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(out);
    for (var k = 0; k < samples.length; k++) {
      var value = samples[k] * gain;
      final position = _emitted + k;
      if (position < _fade) value = value * position / _fade;
      if (fadeOut) {
        final fromEnd = samples.length - 1 - k;
        if (fromEnd < _fade) value = value * fromEnd / _fade;
      }
      data.setInt16(k * 2, value.round().clamp(-32768, 32767), Endian.little);
    }
    _emitted += samples.length;
    return out;
  }
}
