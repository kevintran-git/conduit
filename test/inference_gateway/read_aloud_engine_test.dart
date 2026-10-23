import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart';

import 'package:conduit/inference_gateway/chat_tts/chat_tts_background_lease.dart';
import 'package:conduit/inference_gateway/chat_tts/tts_audio_cache.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_engine.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_store.dart';

const three = 'One two three. Four five six. Seven eight nine.';

class _FakeSink implements PcmAudioSink {
  int fedBytes = 0;
  Timer? _timer;
  void Function(int remainingFrames)? _callback;

  @override
  Future<void> setup({required int sampleRateHz, required int numChannels}) =>
      Future.value();

  @override
  Future<void> setFeedThreshold(int threshold) => Future.value();

  @override
  void setFeedCallback(void Function(int remainingFrames)? callback) {
    _callback = callback;
  }

  @override
  bool start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => _callback?.call(0),
    );
    return true;
  }

  @override
  Future<void> feed(Uint8List bytes) {
    fedBytes += bytes.length;
    return Future.value();
  }

  @override
  Future<void> release() {
    _timer?.cancel();
    _timer = null;
    return Future.value();
  }
}

class _FakeSession implements ik.ElevenLabsTtsSession {
  _FakeSession(
    this.bytesPerSegment,
    this.texts, {
    this.hang = false,
    this.dropWhen,
  });

  final int bytesPerSegment;
  final List<String> texts;
  final bool hang;
  final bool Function(String text)? dropWhen;
  String _text = '';
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get frames => _controller.stream;

  @override
  void appendText(String text, {bool triggerGeneration = true}) {
    _text = text;
    texts.add(text);
  }

  @override
  void flush() {
    if (hang) return;
    if (dropWhen?.call(_text) ?? false) {
      _controller.addError(StateError('dropped'));
      return;
    }
    unawaited(_emit());
  }

  Future<void> _emit() async {
    for (var offset = 0; offset < bytesPerSegment; offset += 4800) {
      await Future<void>.delayed(Duration.zero);
      if (_controller.isClosed) return;
      final length = bytesPerSegment - offset < 4800
          ? bytesPerSegment - offset
          : 4800;
      final bytes = Uint8List(length);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < length; i += 2) {
        final sample = (offset + i) ~/ 2;
        data.setInt16(i, sample.isEven ? 3000 : -3000, Endian.little);
      }
      _controller.add(bytes);
    }
    if (!_controller.isClosed) await _controller.close();
  }

  @override
  Future<void> dispose() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

class _FakeClient implements ik.ElevenLabsTtsClient {
  _FakeClient({
    this.bytesPerSegment = 9600,
    this.fail = false,
    this.hang = false,
    this.silentVoices = const {},
  });

  final int bytesPerSegment;
  final bool fail;
  final bool hang;
  final Set<String> silentVoices;
  bool Function(String text)? dropWhen;
  int opens = 0;
  final List<String> texts = [];
  final List<String> voices = [];

  @override
  String get baseUrl => 'http://fake';

  @override
  String get apiKey => 'k';

  @override
  Future<ik.ElevenLabsTtsSession> openSession({
    required String voice,
    required String model,
  }) async {
    opens++;
    voices.add(voice);
    if (fail) throw StateError('boom');
    return _FakeSession(
      silentVoices.contains(voice) ? 0 : bytesPerSegment,
      texts,
      hang: hang,
      dropWhen: dropWhen,
    );
  }

  @override
  Future<Uint8List> synthesizeFull({
    required String text,
    required String voice,
    required String model,
  }) => throw UnimplementedError();
}

class _FakeLease implements ChatTtsBackgroundLease {
  bool held = false;

  @override
  Future<void> acquire() async {
    held = true;
  }

  @override
  Future<void> release() async {
    held = false;
  }

  @override
  bool get isHeld => held;
}

class _DirCache extends TtsAudioCache {
  _DirCache(this.dir);

  final Directory dir;

  @override
  Future<Directory> directory() async => dir;
}

class _Probe {
  _Probe(ReadAloudEngine engine) {
    engine
      ..onStarted = () {
        startedCount++;
      }
      ..onCompleted = () {
        if (!completed.isCompleted) completed.complete();
      }
      ..onError = (message, heard) {
        errorHeard = heard;
        if (!errored.isCompleted) errored.complete(message);
      }
      ..onVoiceRejected = rejectedVoices.add
      ..onStatus = statuses.add
      ..onWord = (part, start, end) {
        words.add((part, start, end));
      };
  }

  int startedCount = 0;
  bool? errorHeard;
  final List<String> rejectedVoices = [];
  final Completer<void> completed = Completer<void>();
  final Completer<String> errored = Completer<String>();
  final List<ReadAloudStatus> statuses = [];
  final List<(int, int, int)> words = [];
}

ReadAloudEngine _makeEngine(
  _FakeClient client,
  _FakeSink sink,
  Directory dir, {
  ReadAloudStore? store,
  Duration firstAudioDeadline = const Duration(seconds: 15),
}) {
  return ReadAloudEngine(
    firstAudioDeadline: firstAudioDeadline,
    client: client,
    cache: _DirCache(dir),
    store: store ?? ReadAloudStore(),
    lease: _FakeLease(),
    speaker: PcmStreamSpeaker(sink: sink, logScope: 'test'),
  );
}

Future<void> playText(ReadAloudEngine e, String text) {
  return e.play(text: text, parts: [text], voice: 'v', model: 'm');
}

Future<void> _disposeQuietly(ReadAloudEngine engine) async {
  try {
    await engine.dispose();
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('read_aloud_engine');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('plays every sentence and completes', () async {
    final client = _FakeClient();
    final sink = _FakeSink();
    final engine = _makeEngine(client, sink, dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    await probe.completed.future.timeout(const Duration(seconds: 20));
    expect(probe.startedCount, 1);
    expect(client.opens, 3);
    expect(client.texts.toSet(), {
      'One two three.',
      'Four five six.',
      'Seven eight nine.',
    });
    expect(engine.isActive, isFalse);
    expect(engine.snapshot.value, isNull);
    expect(sink.fedBytes, 28800);
    expect(probe.words, isNotEmpty);
    expect(probe.words.first.$1, 0);
    expect(probe.words.first.$2, 0);
    expect(probe.errored.isCompleted, isFalse);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('reuses cached segments', () async {
    final client1 = _FakeClient();
    final engine1 = _makeEngine(client1, _FakeSink(), dir);
    final probe1 = _Probe(engine1);
    await playText(engine1, three);
    await probe1.completed.future.timeout(const Duration(seconds: 20));
    await _disposeQuietly(engine1);

    final client2 = _FakeClient();
    final sink2 = _FakeSink();
    final engine2 = _makeEngine(client2, sink2, dir);
    final probe2 = _Probe(engine2);
    await playText(engine2, three);
    await probe2.completed.future.timeout(const Duration(seconds: 20));
    expect(client2.opens, 0);
    expect(sink2.fedBytes, 28800);
    await _disposeQuietly(engine2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('pauses and resumes', () async {
    final client = _FakeClient(bytesPerSegment: 48000);
    final sink = _FakeSink();
    final engine = _makeEngine(client, sink, dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await engine.pause();
    expect(engine.isPaused, isTrue);
    expect(probe.statuses, contains(ReadAloudStatus.paused));
    expect(engine.snapshot.value!.status, equals(ReadAloudStatus.paused));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.resume();
    expect(probe.statuses.last, equals(ReadAloudStatus.playing));
    await probe.completed.future.timeout(const Duration(seconds: 20));
    expect(sink.fedBytes, greaterThanOrEqualTo(144000));
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('reports an error when synthesis fails', () async {
    final client = _FakeClient(fail: true);
    final engine = _makeEngine(client, _FakeSink(), dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    final message = await probe.errored.future.timeout(
      const Duration(seconds: 25),
    );
    expect(message, 'Could not connect to the gateway.');
    expect(probe.completed.isCompleted, isFalse);
    expect(engine.isActive, isFalse);
    expect(client.opens, greaterThanOrEqualTo(3));
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('fails without retrying when the gateway returns no audio', () async {
    final client = _FakeClient(bytesPerSegment: 0);
    final engine = _makeEngine(client, _FakeSink(), dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    final message = await probe.errored.future.timeout(
      const Duration(seconds: 5),
    );
    expect(message, 'The gateway returned no audio.');
    expect(probe.errorHeard, isFalse);
    expect(probe.rejectedVoices, isEmpty);
    expect(engine.isActive, isFalse);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('falls back to the default voice when the voice is unknown', () async {
    final client = _FakeClient(silentVoices: {'v'});
    final sink = _FakeSink();
    final engine = _makeEngine(client, sink, dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    await probe.completed.future.timeout(const Duration(seconds: 20));
    expect(probe.rejectedVoices, ['v']);
    expect(probe.errored.isCompleted, isFalse);
    expect(sink.fedBytes, 28800);
    expect(client.voices.last, '');
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('gives up when no audio arrives before the deadline', () async {
    final client = _FakeClient(hang: true);
    final engine = _makeEngine(
      client,
      _FakeSink(),
      dir,
      firstAudioDeadline: const Duration(seconds: 1),
    );
    final probe = _Probe(engine);
    await playText(engine, three).timeout(const Duration(seconds: 5));
    final message = await probe.errored.future.timeout(
      const Duration(seconds: 5),
    );
    expect(message, 'The gateway did not respond within 1 s.');
    expect(probe.errorHeard, isFalse);
    expect(engine.isActive, isFalse);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('stops at once while the first sentence is still loading', () async {
    final client = _FakeClient(hang: true);
    final engine = _makeEngine(client, _FakeSink(), dir);
    final probe = _Probe(engine);
    final playing = playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.stop().timeout(const Duration(seconds: 1));
    await playing.timeout(const Duration(seconds: 1));
    expect(engine.isActive, isFalse);
    expect(probe.errored.isCompleted, isFalse);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('pauses at a lost sentence and retries it on resume', () async {
    final client = _FakeClient()
      ..dropWhen = (text) => text == 'Seven eight nine.';
    final sink = _FakeSink();
    final engine = _makeEngine(client, sink, dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!(engine.snapshot.value?.stalled ?? false)) {
      expect(DateTime.now().isBefore(deadline), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(engine.isPaused, isTrue);
    expect(engine.snapshot.value!.segment, 2);
    expect(probe.errored.isCompleted, isFalse);
    client.dropWhen = null;
    await engine.resume();
    await probe.completed.future.timeout(const Duration(seconds: 20));
    expect(sink.fedBytes, 28800);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('stop ends the session without completing', () async {
    final client = _FakeClient(bytesPerSegment: 48000);
    final engine = _makeEngine(client, _FakeSink(), dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.stop();
    expect(engine.isActive, isFalse);
    expect(engine.snapshot.value, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(probe.completed.isCompleted, isFalse);
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('skips to the next sentence', () async {
    final client = _FakeClient(bytesPerSegment: 48000);
    final engine = _makeEngine(client, _FakeSink(), dir);
    final probe = _Probe(engine);
    await playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.skipSegments(1);
    expect(engine.snapshot.value!.segment, equals(1));
    await probe.completed.future.timeout(const Duration(seconds: 20));
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('resumes from the saved mark', () async {
    final store = ReadAloudStore();
    final client = _FakeClient(bytesPerSegment: 48000);
    final engine = _makeEngine(client, _FakeSink(), dir, store: store);
    _Probe(engine);
    await playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.skipSegments(1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await engine.stop();
    await playText(engine, three);
    expect(engine.snapshot.value!.segment, equals(1));
    await engine.stop();
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('seekTo moves the position', () async {
    final client = _FakeClient(bytesPerSegment: 48000);
    final engine = _makeEngine(client, _FakeSink(), dir);
    _Probe(engine);
    await playText(engine, three);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await engine.seekTo(const Duration(milliseconds: 2100));
    expect(engine.snapshot.value!.segment, equals(2));
    await engine.stop();
    await _disposeQuietly(engine);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
