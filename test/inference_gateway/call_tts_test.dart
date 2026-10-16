import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/voice_call/application/call_tts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart';

class _FakeTtsSession implements ik.ElevenLabsTtsSession {
  _FakeTtsSession({Future<void>? disposeFuture})
    : _disposeFuture = disposeFuture;

  final Future<void>? _disposeFuture;
  final StreamController<Uint8List> controller =
      StreamController<Uint8List>.broadcast();
  final List<String> appended = <String>[];
  bool disposed = false;

  @override
  Stream<Uint8List> get frames => controller.stream;

  @override
  void appendText(String text, {bool triggerGeneration = true}) {
    appended.add(text);
  }

  @override
  void flush() {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await (_disposeFuture ?? Future<void>.value());
  }
}

class _FakeTtsClient extends ik.ElevenLabsTtsClient {
  _FakeTtsClient(this._onOpen)
    : super(baseUrl: 'https://gateway.test', apiKey: 'key');

  final Future<ik.ElevenLabsTtsSession> Function() _onOpen;

  @override
  Future<ik.ElevenLabsTtsSession> openSession({
    required String voice,
    required String model,
  }) => _onOpen();
}

class _FakeSpeaker implements PcmStreamSpeaker {
  int streamCalls = 0;
  Future<void>? stopFuture;
  Future<void>? disposeFuture;

  @override
  Future<void> stream(
    Stream<Uint8List> frames, {
    void Function()? onFirstFrame,
    void Function(int frameCount, int byteCount)? onProgress,
  }) async {
    streamCalls++;
  }

  @override
  Future<void> stop({bool hardFlush = false}) =>
      stopFuture ?? Future<void>.value();

  @override
  Future<void> dispose() => disposeFuture ?? Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'stop during WS handshake disposes newly opened session without starting playback',
    () async {
      final handshake = Completer<ik.ElevenLabsTtsSession>();
      final session = _FakeTtsSession();
      final speaker = _FakeSpeaker();
      final tts = CallTts(
        client: _FakeTtsClient(() => handshake.future),
        config: GatewayConfig.defaults(),
        speaker: speaker,
      );

      final openFuture = tts.open();
      tts.append('hello');
      final stopFuture = tts.stop();
      handshake.complete(session);

      await Future.wait(<Future<void>>[openFuture, stopFuture]);

      check(session.disposed).isTrue();
      check(speaker.streamCalls).equals(0);
      check(session.appended).isEmpty();
    },
  );

  test(
    'dispose does not await hung speaker or session teardown',
    () async {
      final never = Completer<void>();
      final session = _FakeTtsSession(disposeFuture: never.future);
      final speaker = _FakeSpeaker()
        ..stopFuture = never.future
        ..disposeFuture = never.future;
      final tts = CallTts(
        client: _FakeTtsClient(() async => session),
        config: GatewayConfig.defaults(),
        speaker: speaker,
      );

      await tts.open();
      await tts.dispose().timeout(const Duration(milliseconds: 100));
    },
  );
}
