import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/audio/pcm_stream_speaker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_pcm_sound/methods');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<MethodCall> feedCalls() =>
      calls.where((c) => c.method == 'feed').toList();

  test(
    'holds the first chunks in a jitter buffer instead of feeding each one straight through',
    () async {
      final speaker = PcmStreamSpeaker(sampleRateHz: 1000, jitterBufferMs: 100);
      final controller = StreamController<Uint8List>();
      var fired = false;

      final done = speaker.stream(
        controller.stream,
        onFirstFrame: () => fired = true,
      );

      controller.add(Uint8List(100));
      await pumpEventQueue();
      check(feedCalls()).isEmpty();
      check(fired).isFalse();

      controller.add(Uint8List(150));
      await pumpEventQueue();
      check(feedCalls()).length.equals(1);
      final primed = feedCalls().single.arguments['buffer'] as Uint8List;
      check(primed.length).equals(250);
      check(fired).isTrue();

      controller.add(Uint8List(50));
      await pumpEventQueue();
      check(feedCalls()).length.equals(2);
      final passthrough = feedCalls().last.arguments['buffer'] as Uint8List;
      check(passthrough.length).equals(50);

      await speaker.dispose();
      await done;
      await controller.close();
    },
  );

  test('flushes a short turn that never reaches the jitter threshold', () async {
    final speaker = PcmStreamSpeaker(sampleRateHz: 1000, jitterBufferMs: 100);
    final controller = StreamController<Uint8List>();
    var fired = false;

    final done = speaker.stream(
      controller.stream,
      onFirstFrame: () => fired = true,
    );

    controller.add(Uint8List(40));
    await pumpEventQueue();
    check(feedCalls()).isEmpty();

    await controller.close();
    await pumpEventQueue();
    check(feedCalls()).length.equals(1);
    check(feedCalls().single.arguments['buffer'] as Uint8List).length.equals(
      40,
    );
    check(fired).isTrue();

    await speaker.dispose();
    await done;
  });
}
