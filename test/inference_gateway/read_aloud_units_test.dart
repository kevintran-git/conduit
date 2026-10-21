import 'dart:typed_data';

import 'package:conduit/inference_gateway/read_aloud/audio_shaper.dart';
import 'package:conduit/inference_gateway/read_aloud/playback_clock.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_plan.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_store.dart';
import 'package:conduit/inference_gateway/read_aloud/speech_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List pcm(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}

List<int> samplesOf(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 2; i++)
      data.getInt16(i * 2, Endian.little),
  ];
}

void main() {
  group('speech_text', () {
    test('romanToInt converts valid numerals only', () {
      expect(romanToInt('IV'), 4);
      expect(romanToInt('XIV'), 14);
      expect(romanToInt('MCMXC'), 1990);
      expect(romanToInt('IIII'), isNull);
      expect(romanToInt('ABC'), isNull);
      expect(romanToInt(''), isNull);
    });

    test('spokenWord expands numerals after division words', () {
      expect(spokenWord('IV', previous: 'Chapter'), '4');
      expect(spokenWord('IV.', previous: 'chapter'), '4.');
      expect(spokenWord('IV', previous: 'the'), 'IV');
      expect(spokenWord('C', previous: 'Part'), 'C');
      expect(spokenWord('I', previous: 'Part'), 'I');
      expect(spokenWord('I', previous: 'Chapter'), '1');
    });

    test('spokenWord drops emoji', () {
      expect(spokenWord('\u{1F389}'), '');
      expect(spokenWord('wow\u{1F389}'), 'wow');
    });

    test('spokenWord collapses repeated marks and quotes', () {
      expect(spokenWord('no!!!'), 'no!');
      expect(spokenWord('wait....'), 'wait...');
      expect(spokenWord('said".'), 'said."');
    });

    test('spokenWord applies pronunciations', () {
      expect(spokenWord('GIF,', pronunciations: {'gif': 'jif'}), 'jif,');
    });

    test('normalizeWords uses the previous word for numerals', () {
      expect(
        normalizeWords(['Chapter', 'IV', 'begins']),
        ['Chapter', '4', 'begins'],
      );
    });

    test('parsePronunciations keeps single-word keys with values', () {
      expect(
        parsePronunciations(
          'GIF=jif\n bad line\nnginx = engine x\ntwo words=x\n=y\nk=',
        ),
        {'gif': 'jif', 'nginx': 'engine x'},
      );
    });
  });

  group('read_aloud_plan', () {
    test('pauseWeight weighs sentence and clause ends', () {
      expect(pauseWeight('end.'), 6);
      expect(pauseWeight('end?"'), 6);
      expect(pauseWeight('a,'), 3);
      expect(pauseWeight('word'), 0);
      expect(pauseWeight('"'), 0);
    });

    test('build splits parts into sentence segments with paragraph marks', () {
      final plan = ReadAloudPlan.build(
        fullText: 'Hello world. Second sentence here!\n\nNew paragraph.',
        parts: ['Hello world. Second sentence here!', 'New paragraph.'],
      );
      expect(plan.segments.length, 3);
      expect(plan.partOffsets, [0, 36]);
      expect(plan.paragraphStarts, {0, 1});

      final seg0 = plan.segments[0];
      expect(seg0.partIndex, 0);
      expect(seg0.start, 0);
      expect(seg0.end, 12);
      expect(seg0.spokenText, 'Hello world.');
      expect(seg0.endsParagraph, false);
      expect(seg0.words.map((w) => w.weight).toList(), [5, 12]);
      expect(seg0.totalWeight, 17);

      final seg1 = plan.segments[1];
      expect(seg1.partIndex, 0);
      expect(seg1.start, 13);
      expect(seg1.end, 34);
      expect(seg1.endsParagraph, true);

      final seg2 = plan.segments[2];
      expect(seg2.partIndex, 1);
      expect(seg2.start, 0);
      expect(seg2.end, 14);
      expect(seg2.endsParagraph, true);
    });

    test('build without a newline between parts starts no new paragraph', () {
      final plan = ReadAloudPlan.build(
        fullText: 'Hello world. Second sentence here! New paragraph.',
        parts: ['Hello world. Second sentence here!', 'New paragraph.'],
      );
      expect(plan.paragraphStarts, {0});
      expect(plan.segments[1].endsParagraph, false);
      expect(plan.segments[2].endsParagraph, true);
    });

    test('build splits long sentences at clauses and at the word limit', () {
      final words = List.generate(130, (i) => i == 39 ? 'w$i,' : 'w$i');
      final part = words.join(' ');
      final plan = ReadAloudPlan.build(fullText: part, parts: [part]);
      expect(plan.segments.map((s) => s.words.length).toList(), [40, 60, 30]);
    });

    test('build gives emoji words zero weight and no speech', () {
      const part = 'Great \u{1F389} job.';
      final plan = ReadAloudPlan.build(fullText: part, parts: [part]);
      expect(plan.segments.length, 1);
      final seg = plan.segments[0];
      expect(seg.words.map((w) => w.weight).toList(), [5, 0, 10]);
      expect(seg.spokenText, 'Great job.');
    });

    test('build marks emoji-only parts as silent', () {
      const part = '\u{1F389}';
      final plan = ReadAloudPlan.build(fullText: part, parts: [part]);
      expect(plan.segments.length, 1);
      expect(plan.segments[0].silent, true);
    });

    test('segment timings divide duration by word weight', () {
      final plan = ReadAloudPlan.build(
        fullText: 'Hello world. Second sentence here!\n\nNew paragraph.',
        parts: ['Hello world. Second sentence here!', 'New paragraph.'],
      );
      final seg0 = plan.segments[0];
      final timings = seg0.wordTimings(1700);
      expect(timings.length, 2);
      expect(timings[0].startMs, 0);
      expect(timings[0].endMs, 500);
      expect(timings[1].startMs, 500);
      expect(timings[1].endMs, 1700);
      expect(seg0.wordIndexAt(499, 1700), 0);
      expect(seg0.wordIndexAt(500, 1700), 1);
      expect(seg0.wordIndexAt(5000, 1700), 1);
      expect(seg0.msForWord(1, 1700), 500);
      expect(seg0.msForWord(9, 1700), 500);
    });

    test('segmentAtPartOffset finds the segment covering an offset', () {
      final plan = ReadAloudPlan.build(
        fullText: 'Hello world. Second sentence here!\n\nNew paragraph.',
        parts: ['Hello world. Second sentence here!', 'New paragraph.'],
      );
      expect(plan.segmentAtPartOffset(0, 0), 0);
      expect(plan.segmentAtPartOffset(0, 13), 1);
      expect(plan.segmentAtPartOffset(0, 20), 1);
      expect(plan.segmentAtPartOffset(1, 0), 2);
      expect(plan.segmentAtPartOffset(1, 5), 2);
    });
  });

  group('audio_shaper', () {
    test('gainForRms normalizes toward target and clamps gain', () {
      expect(gainForRms(0.5), 1);
      expect(gainForRms(3276.8), closeTo(1.0, 1e-9));
      expect(gainForRms(327.68), closeTo(2.8183829, 1e-6));
      expect(gainForRms(32767), closeTo(0.3548134, 1e-6));
    });

    test('caps leading and trailing silence', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      final input = pcm([
        ...List.filled(500, 0),
        ...List.filled(100, 1000),
        ...List.filled(500, 0),
      ]);
      final out = [
        ...samplesOf(shaper.add(input)),
        ...samplesOf(shaper.finish()),
      ];
      expect(out.length, 520);
      expect(out.first, 0);
      expect(out[170], 1000);
      expect(out.last, 0);
    });

    test('fades in the first samples of a segment', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      final samples = samplesOf(shaper.add(pcm(List.filled(100, 1000))));
      expect(samples[0], 0);
      expect(samples[4], 500);
      expect(samples[8], 1000);
    });

    test('keeps byte alignment across odd-length chunks', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      final bytes = pcm(List.filled(10, 1000));
      final a = shaper.add(Uint8List.sublistView(bytes, 0, 3));
      final b = shaper.add(Uint8List.sublistView(bytes, 3, 20));
      final f = shaper.finish();
      expect(a.length + b.length + f.length, 20);
    });

    test('applies gain with clamping to the sample range', () {
      final quiet = SegmentShaper(gain: 2, sampleRate: 1000);
      expect(samplesOf(quiet.add(pcm(List.filled(50, 1000))))[20], 2000);
      final loud = SegmentShaper(gain: 4, sampleRate: 1000);
      expect(samplesOf(loud.add(pcm(List.filled(50, 10000))))[20], 32767);
    });

    test('holds silence until voiced audio follows', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      expect(samplesOf(shaper.add(pcm(List.filled(100, 1000)))).length, 100);
      expect(shaper.add(pcm(List.filled(50, 0))).length, 0);
      expect(samplesOf(shaper.add(pcm(List.filled(100, 1000)))).length, 150);
    });

    test('measuredGain needs enough voiced samples', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      shaper.add(pcm(List.filled(400, 3277)));
      expect(shaper.measuredGain, isNull);
      shaper.add(pcm(List.filled(200, 3277)));
      expect(shaper.measuredGain, closeTo(1.0, 0.01));
    });

    test('finish emits nothing without loud audio', () {
      final shaper = SegmentShaper(gain: 1, sampleRate: 1000);
      shaper.add(pcm(List.filled(300, 0)));
      expect(shaper.finish().length, 0);
    });
  });

  group('playback_clock', () {
    test('starts unstarted with no position', () {
      final clock = PlaybackClock(bytesPerSecond: 1000, now: () => Duration.zero);
      expect(clock.started, false);
      expect(clock.playedBytes, 0);
      expect(clock.position, isNull);
    });

    test('tracks played bytes and position across segments', () {
      var now = Duration.zero;
      final clock = PlaybackClock(bytesPerSecond: 1000, now: () => now);

      clock.fed(0, 0, 500);
      clock.start();
      now = const Duration(milliseconds: 200);
      expect(clock.playedBytes, 200);
      expect(clock.position, (segment: 0, offset: 200));
      expect(clock.bufferedBytes, 300);

      clock.fed(0, 500, 500);
      expect(clock.spans.length, 1);

      clock.fed(1, 0, 1000);
      expect(clock.spans.length, 2);

      now = const Duration(milliseconds: 1200);
      expect(clock.position, (segment: 1, offset: 200));

      now = const Duration(milliseconds: 3000);
      expect(clock.playedBytes, 2000);
      expect(clock.starved, true);

      clock.fed(2, 0, 100);
      now = const Duration(milliseconds: 3050);
      expect(clock.playedBytes, 2050);
      expect(clock.position, (segment: 2, offset: 50));
    });
  });

  group('read_aloud_store', () {
    test('saveMark round-trips and drops legacy keys', () async {
      SharedPreferences.setMockInitialValues({'gateway_tts_pos_old': 5});
      final store = ReadAloudStore();
      await store.saveMark('k', (part: 2, offset: 15));
      expect(await store.loadMark('k'), (part: 2, offset: 15));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('gateway_tts_pos_old'), false);
    });

    test('clearMark removes a saved mark', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ReadAloudStore();
      await store.saveMark('k', (part: 2, offset: 15));
      await store.clearMark('k');
      expect(await store.loadMark('k'), isNull);
    });

    test('saveMark evicts the oldest mark beyond 64 entries', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ReadAloudStore();
      for (var i = 0; i <= 64; i++) {
        await store.saveMark('k$i', (part: i, offset: 0));
      }
      expect(await store.loadMark('k0'), isNull);
      expect(await store.loadMark('k1'), isNotNull);
      expect(await store.loadMark('k64'), isNotNull);
    });

    test('saveMark moves re-saved keys to the newest position', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ReadAloudStore();
      for (var i = 0; i < 64; i++) {
        await store.saveMark('k$i', (part: i, offset: 0));
      }
      await store.saveMark('k0', (part: 0, offset: 0));
      await store.saveMark('k64', (part: 64, offset: 0));
      expect(await store.loadMark('k1'), isNull);
      expect(await store.loadMark('k0'), isNotNull);
    });

    test('rate and gain round-trip per voice', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ReadAloudStore();
      expect(await store.loadRate('v'), isNull);
      await store.saveRate('v', 61.5);
      expect(await store.loadRate('v'), 61.5);
      expect(await store.loadGain('v'), isNull);
      await store.saveGain('v', 1.25);
      expect(await store.loadGain('v'), 1.25);
    });

    test('loadMark rejects malformed values', () async {
      SharedPreferences.setMockInitialValues({'gateway_read_aloud_pos_x': 'bad'});
      final store = ReadAloudStore();
      expect(await store.loadMark('x'), isNull);
    });
  });
}
