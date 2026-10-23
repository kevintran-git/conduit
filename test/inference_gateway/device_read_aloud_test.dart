import 'package:conduit/inference_gateway/read_aloud/device_read_aloud.dart';
import 'package:inference_kit/read_aloud.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parts = ['One two three.', 'Four five six.', 'Seven eight nine.'];
  final text = parts.join(' ');

  late List<String> spoken;
  late List<String> calls;
  late DeviceReadAloud device;

  setUp(() {
    spoken = [];
    calls = [];
    device = DeviceReadAloud(
      plan: ReadAloudPlan.build(fullText: text, parts: parts),
      speak: (value) async => spoken.add(value),
      pause: () async => calls.add('pause'),
      resume: () async => calls.add('resume'),
    );
  });

  test('publishes a device snapshot while loading', () async {
    await device.start(0);
    final snapshot = device.snapshot.value!;
    expect(snapshot.device, isTrue);
    expect(snapshot.status, ReadAloudStatus.loading);
    expect(spoken.single, text);
  });

  test('follows chunk and word progress relative to the start', () async {
    await device.start(1);
    expect(spoken.single, 'Four five six. Seven eight nine.');
    device.onChunk(1);
    expect(device.snapshot.value!.segment, 2);
    device.onWord(6);
    expect(device.snapshot.value!.word, 1);
    expect(device.snapshot.value!.status, ReadAloudStatus.playing);
  });

  test('pauses and resumes through the device engine', () async {
    await device.start(0);
    device.onChunk(0);
    await device.togglePause();
    expect(device.snapshot.value!.isPaused, isTrue);
    await device.togglePause();
    expect(device.snapshot.value!.isPaused, isFalse);
    expect(calls, ['pause', 'resume']);
  });

  test('skips sentences by restarting speech', () async {
    await device.start(0);
    device.onChunk(0);
    await device.skipSegments(1);
    expect(spoken.last, 'Four five six. Seven eight nine.');
    await device.skipSegments(-1);
    expect(spoken.last, text);
  });

  test('close clears the snapshot and ignores later progress', () async {
    await device.start(0);
    device.close();
    device.onChunk(1);
    expect(device.snapshot.value, isNull);
  });
}
