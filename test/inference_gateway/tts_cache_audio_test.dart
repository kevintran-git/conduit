import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/inference_gateway/chat_tts/pcm_wav_audio_source.dart';
import 'package:conduit/inference_gateway/chat_tts/tts_audio_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pcm byte math', () {
    test('one second of 24 kHz mono 16-bit is 48000 bytes', () {
      expect(kTtsBytesPerSecond, 48000);
      expect(ttsBytesToDuration(48000), const Duration(seconds: 1));
      expect(ttsDurationToBytes(const Duration(seconds: 1)), 48000);
    });

    test('durations round down to a whole frame', () {
      expect(ttsDurationToBytes(const Duration(microseconds: 1)), 0);
      expect(ttsDurationToBytes(const Duration(milliseconds: -5)), 0);
      expect(ttsDurationToBytes(const Duration(milliseconds: 10)) % 2, 0);
    });

    test('keys separate voice and model', () {
      final a = TtsAudioCache.keyFor(text: 'hello', voice: 'v1', model: 'm1');
      final b = TtsAudioCache.keyFor(text: 'hello', voice: 'v2', model: 'm1');
      final c = TtsAudioCache.keyFor(text: 'hello', voice: 'v1', model: 'm2');
      final d = TtsAudioCache.keyFor(text: ' hello ', voice: 'v1', model: 'm1');
      expect(a, isNot(b));
      expect(a, isNot(c));
      expect(a, d);
    });
  });

  group('PcmFileAudioSource', () {
    late Directory dir;
    late File pcm;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tts_cache_test');
      pcm = File('${dir.path}/sample.pcm');
      await pcm.writeAsBytes(
        Uint8List.fromList(List<int>.generate(1000, (i) => i % 256)),
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('declares a 44-byte header plus the pcm length', () async {
      final source = PcmFileAudioSource(file: pcm, pcmByteLength: 1000);
      expect(source.sourceLength, 1044);
      final response = await source.request();
      expect(response.contentLength, 1044);
      expect(response.offset, 0);
      final bytes = await _collect(response.stream);
      expect(bytes.length, 1044);
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      final view = ByteData.sublistView(bytes);
      expect(view.getUint32(4, Endian.little), 1036);
      expect(view.getUint32(24, Endian.little), kTtsSampleRateHz);
      expect(view.getUint32(40, Endian.little), 1000);
      expect(bytes[44], 0);
      expect(bytes[45], 1);
    });

    test('serves a range that spans the header boundary', () async {
      final source = PcmFileAudioSource(file: pcm, pcmByteLength: 1000);
      final response = await source.request(40, 50);
      final bytes = await _collect(response.stream);
      expect(response.offset, 40);
      expect(response.contentLength, 10);
      expect(bytes.length, 10);
      expect(bytes.sublist(0, 4), <int>[0xE8, 0x03, 0, 0]);
      expect(bytes.sublist(4), <int>[0, 1, 2, 3, 4, 5]);
    });

    test('serves a range entirely inside the pcm body', () async {
      final source = PcmFileAudioSource(file: pcm, pcmByteLength: 1000);
      final response = await source.request(144, 154);
      final bytes = await _collect(response.stream);
      expect(bytes, List<int>.generate(10, (i) => 100 + i));
    });

    test('clamps a range past the end', () async {
      final source = PcmFileAudioSource(file: pcm, pcmByteLength: 1000);
      final response = await source.request(1040, 5000);
      final bytes = await _collect(response.stream);
      expect(bytes.length, 4);
    });
  });
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
  }
  return Uint8List.fromList(out);
}
