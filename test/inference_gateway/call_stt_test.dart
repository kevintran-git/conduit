import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/services/native_stt_service.dart';
import 'package:conduit/inference_gateway/voice_call/application/call_stt.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNativeSttService extends NativeSttService {
  final List<StreamController<NativeSttEvent>> controllers =
      <StreamController<NativeSttEvent>>[];

  @override
  Future<Stream<NativeSttEvent>> startListening({
    String? localeId,
    bool preserveAudioSession = false,
    bool emitPartialResults = true,
    bool accumulateResults = true,
    bool allowOnlineFallback = true,
  }) async {
    final controller = StreamController<NativeSttEvent>();
    controllers.add(controller);
    return controller.stream;
  }

  @override
  Future<void> stopListening() async {}
}

void main() {
  test('folds accumulated transcript into committed text before manual-EOS restart', () async {
    final nativeStt = _FakeNativeSttService();
    final stt = DeviceCallStt(
      pauseFor: const Duration(seconds: 2),
      manualEosOnly: true,
      stt: nativeStt,
    );
    addTearDown(stt.dispose);

    final events = <SttEvent>[];
    final sub = stt.events.listen(events.add);
    addTearDown(sub.cancel);

    await stt.start();
    check(nativeStt.controllers).length.equals(1);

    nativeStt.controllers[0].add(
      const NativeSttEvent(type: 'result', text: 'first part'),
    );
    await Future<void>.delayed(Duration.zero);

    await nativeStt.controllers[0].close();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    check(nativeStt.controllers).length.equals(2);

    nativeStt.controllers[1].add(
      const NativeSttEvent(type: 'result', text: 'second part'),
    );
    await Future<void>.delayed(Duration.zero);

    await stt.requestFinal();
    await Future<void>.delayed(Duration.zero);

    check(events.last.isFinal).isTrue();
    check(events.last.text).equals('first part second part');
  });
}
