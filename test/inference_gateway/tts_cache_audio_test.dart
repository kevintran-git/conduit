import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/inference_gateway/chat_tts/tts_audio_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  _writerGrowth();

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
}

void _writerGrowth() {
  group('TtsCacheWriter growth', () {
    late Directory dir;
    late TtsAudioCache cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tts_growth_test');
      cache = _FixedDirCache(dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('awaitBytesBeyond resolves when the next chunk lands', () async {
      final writer = await cache.openWriter(key: 'k');
      var resolved = false;
      final waiter = writer.awaitBytesBeyond(0).then((_) => resolved = true);
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);
      writer.add(Uint8List(64));
      await waiter;
      expect(resolved, isTrue);
      expect(writer.writtenBytes, 64);
      await writer.finish();
    });

    test('awaitBytesBeyond resolves when the writer closes short', () async {
      final writer = await cache.openWriter(key: 'k');
      writer.add(Uint8List(8));
      final waiter = writer.awaitBytesBeyond(1000);
      await writer.finish();
      await waiter;
      expect(writer.isClosed, isTrue);
    });

    test('finish right after add keeps every queued chunk', () async {
      final writer = await cache.openWriter(key: 'k');
      writer.add(Uint8List(32));
      writer.add(Uint8List(16));
      await writer.finish();
      expect(await cache.availableBytes('k'), 48);
      expect(await cache.isComplete('k'), isTrue);
    });

    test('awaitBytesBeyond returns at once past the target', () async {
      final writer = await cache.openWriter(key: 'k');
      writer.add(Uint8List(16));
      await writer.awaitBytesBeyond(8);
      await writer.finish();
    });
  });
}

class _FixedDirCache extends TtsAudioCache {
  _FixedDirCache(this._dir);

  final Directory _dir;

  @override
  Future<Directory> directory() async => _dir;
}
