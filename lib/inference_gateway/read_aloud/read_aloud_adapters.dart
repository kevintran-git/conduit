import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:inference_kit/read_aloud.dart';
import 'package:pcm_call_audio/pcm_call_audio.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../chat_tts/chat_tts_background_lease.dart';
import '../chat_tts/tts_audio_cache.dart';

class SpeakerPcmOutput implements PcmOutput {
  SpeakerPcmOutput([PcmStreamSpeaker? speaker])
    : _speaker = speaker ?? PcmStreamSpeaker(logScope: 'gateway/read-aloud');

  final PcmStreamSpeaker _speaker;

  @override
  Future<void> stream(Stream<Uint8List> pcm, {void Function()? onFirstFrame}) =>
      _speaker.stream(pcm, onFirstFrame: onFirstFrame);

  @override
  Future<void> stop({bool hardFlush = false}) =>
      _speaker.stop(hardFlush: hardFlush);

  @override
  Future<void> dispose() => _speaker.dispose();
}

class TtsReadAloudCache implements ReadAloudCache {
  TtsReadAloudCache([TtsAudioCache? cache]) {
    _cache = cache ?? TtsAudioCache(protectedKeys: () async => _protect);
  }

  late final TtsAudioCache _cache;
  Set<String> _protect = const {};

  @override
  String keyFor({
    required String text,
    required String voice,
    required String model,
  }) => TtsAudioCache.keyFor(text: text, voice: voice, model: model);

  @override
  Future<int?> completeLength(String key) async {
    if (!await _cache.isComplete(key)) return null;
    final bytes = await _cache.availableBytes(key);
    return bytes > 0 ? bytes : null;
  }

  @override
  Future<Uint8List?> read(String key) async =>
      (await _cache.pcmFile(key)).readAsBytes();

  @override
  Future<void> write(String key, Uint8List pcm) async {
    final writer = await _cache.openWriter(key: key);
    writer.add(pcm);
    await writer.finish();
  }

  @override
  Future<void> prune(Set<String> protect) {
    _protect = protect;
    return _cache.prune();
  }
}

class ConduitReadAloudHost implements ReadAloudHost {
  ConduitReadAloudHost({ChatTtsBackgroundLease? lease})
    : _lease = lease ?? ChatTtsBackgroundLease();

  final ChatTtsBackgroundLease _lease;
  ReadAloudEngine? engine;
  AudioSession? _session;
  bool _bound = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptSub;
  StreamSubscription<void>? _noisySub;

  @override
  Future<void> acquire() async {
    unawaited(_lease.acquire());
    await _bind();
    try {
      await _session?.setActive(true);
    } catch (_) {}
  }

  @override
  Future<void> release() => _lease.release();

  Future<void> _bind() async {
    if (_bound) return;
    _bound = true;
    try {
      final session = _session = await AudioSession.instance;
      _interruptSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          if (event.type == AudioInterruptionType.pause) {
            engine?.interruptionBegan();
          }
          return;
        }
        engine?.interruptionEnded();
      });
      _noisySub = session.becomingNoisyEventStream.listen(
        (_) => engine?.becameNoisy(),
      );
    } catch (error) {
      DebugLogger.log(
        'audio-session-unavailable',
        scope: 'gateway/read-aloud',
        data: {'error': error.toString()},
      );
    }
  }

  Future<void> dispose() async {
    await _interruptSub?.cancel();
    await _noisySub?.cancel();
  }
}
