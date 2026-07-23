import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/inference_gateway/sync/owui_mirror_outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<dynamic> caches;
  late OwuiMirrorOutbox outbox;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('owui-mirror-outbox-test');
    Hive.init(tempDir.path);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    outbox = OwuiMirrorOutbox();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('markDirty queues a conversation, markFlushed clears it', () async {
    await outbox.markDirty('c1');
    check(outbox.hasPending('c1')).isTrue();
    check(outbox.pendingCount()).equals(1);

    await outbox.markFlushed('c1');
    check(outbox.hasPending('c1')).isFalse();
    check(outbox.pendingCount()).equals(0);
  });

  test('recordFailure bumps retries and backs off exponentially', () async {
    await outbox.markDirty('c1');

    await outbox.recordFailure('c1', Exception('boom'));
    final afterFirst = outbox.pending().single;
    check(afterFirst.retries).equals(1);
    check(afterFirst.failed).isFalse();
    final firstBackoff = afterFirst.nextAttemptAt!.difference(DateTime.now());
    check(firstBackoff.inSeconds).isGreaterOrEqual(4);
    check(firstBackoff.inSeconds).isLessOrEqual(6);

    await outbox.recordFailure('c1', Exception('boom again'));
    final afterSecond = outbox.pending().single;
    check(afterSecond.retries).equals(2);
    final secondBackoff = afterSecond.nextAttemptAt!.difference(DateTime.now());
    check(secondBackoff.inSeconds).isGreaterOrEqual(9);
    check(secondBackoff.inSeconds).isLessOrEqual(11);
  });

  test('backoff is capped and entry flags failed at maxRetries', () async {
    await outbox.markDirty('c1');

    for (var i = 0; i < OwuiMirrorOutbox.maxRetries; i++) {
      await outbox.recordFailure('c1', Exception('fail $i'));
    }

    final entry = outbox.pending().single;
    check(entry.retries).equals(OwuiMirrorOutbox.maxRetries);
    check(entry.failed).isTrue();
    check(outbox.failedCount()).equals(1);

    final backoff = entry.nextAttemptAt!.difference(DateTime.now());
    check(backoff.inSeconds).isLessOrEqual(300);
  });

  test('a failing entry is never dropped from the queue', () async {
    await outbox.markDirty('c1');
    for (var i = 0; i < OwuiMirrorOutbox.maxRetries + 5; i++) {
      await outbox.recordFailure('c1', Exception('fail $i'));
    }
    check(outbox.hasPending('c1')).isTrue();
    check(outbox.pendingCount()).equals(1);
  });

  test('markDirty on a failed entry resets failure state for immediate retry', () async {
    await outbox.markDirty('c1');
    for (var i = 0; i < OwuiMirrorOutbox.maxRetries; i++) {
      await outbox.recordFailure('c1', Exception('fail $i'));
    }
    check(outbox.pending().single.failed).isTrue();

    await outbox.markDirty('c1');
    final entry = outbox.pending().single;
    check(entry.failed).isFalse();
    check(entry.retries).equals(0);
    check(entry.nextAttemptAt).isNull();
    check(entry.lastError).isNull();
  });

  test('resetBackoff clears failed/backoff state across all entries', () async {
    await outbox.markDirty('c1');
    await outbox.markDirty('c2');
    for (var i = 0; i < OwuiMirrorOutbox.maxRetries; i++) {
      await outbox.recordFailure('c1', Exception('fail $i'));
    }
    await outbox.recordFailure('c2', Exception('fail once'));

    await outbox.resetBackoff();

    for (final entry in outbox.pending()) {
      check(entry.failed).isFalse();
      check(entry.nextAttemptAt).isNull();
    }
  });

  test('recordFailure on an unknown conversation is a no-op', () async {
    await outbox.recordFailure('missing', Exception('boom'));
    check(outbox.pendingCount()).equals(0);
  });

  test('corrupted entry payloads are skipped rather than thrown', () async {
    await outbox.markDirty('c1');
    await caches.put('owui_mirror::c2', 'not-json');

    check(outbox.pending().map((e) => e.conversationId)).deepEquals(['c1']);
    check(outbox.pendingCount()).equals(1);
  });
}
