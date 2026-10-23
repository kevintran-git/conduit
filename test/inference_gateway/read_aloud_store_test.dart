import 'package:conduit/inference_gateway/read_aloud/read_aloud_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
      SharedPreferences.setMockInitialValues({
        'gateway_read_aloud_pos_x': 'bad',
      });
      final store = ReadAloudStore();
      expect(await store.loadMark('x'), isNull);
    });
  });
}
