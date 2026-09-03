// ignore_for_file: experimental_member_use
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import 'tts_audio_cache.dart';

const int kWavHeaderBytes = 44;

Uint8List buildWavHeader({
  required int pcmByteLength,
  int sampleRateHz = kTtsSampleRateHz,
  int numChannels = kTtsNumChannels,
}) {
  final blockAlign = numChannels * kTtsBytesPerSample;
  final byteRate = sampleRateHz * blockAlign;
  final header = ByteData(kWavHeaderBytes);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcmByteLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, numChannels, Endian.little);
  header.setUint32(24, sampleRateHz, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, kTtsBytesPerSample * 8, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcmByteLength, Endian.little);
  return header.buffer.asUint8List();
}

class PcmFileAudioSource extends StreamAudioSource {
  PcmFileAudioSource({required this.file, required this.pcmByteLength})
    : _header = buildWavHeader(pcmByteLength: pcmByteLength);

  final File file;
  final int pcmByteLength;
  final Uint8List _header;

  int get sourceLength => _header.length + pcmByteLength;

  Duration get pcmDuration => ttsBytesToDuration(pcmByteLength);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final total = sourceLength;
    final from = (start ?? 0).clamp(0, total);
    final to = (end ?? total).clamp(from, total);

    final parts = <Stream<List<int>>>[];
    if (from < _header.length) {
      final headerEnd = to < _header.length ? to : _header.length;
      parts.add(Stream<List<int>>.value(_header.sublist(from, headerEnd)));
    }
    final pcmStart = from > _header.length ? from - _header.length : 0;
    final pcmEnd = to - _header.length;
    if (pcmEnd > pcmStart) {
      parts.add(file.openRead(pcmStart, pcmEnd));
    }

    return StreamAudioResponse(
      sourceLength: total,
      contentLength: to - from,
      offset: from,
      stream: _concat(parts),
      contentType: 'audio/wav',
    );
  }

  static Stream<List<int>> _concat(List<Stream<List<int>>> parts) async* {
    for (final part in parts) {
      yield* part;
    }
  }
}
