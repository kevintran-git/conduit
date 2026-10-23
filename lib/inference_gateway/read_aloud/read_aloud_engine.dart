import 'dart:async';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:pcm_call_audio/pcm_call_audio.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../chat_tts/chat_tts_background_lease.dart';
import '../chat_tts/tts_audio_cache.dart';
import 'audio_shaper.dart';
import 'playback_clock.dart';
import 'read_aloud_plan.dart';
import 'read_aloud_store.dart';
import 'segment_audio.dart';
import 'time_stretch.dart';

enum ReadAloudStatus { loading, playing, paused }

class ReadAloudSnapshot {
  const ReadAloudSnapshot({
    required this.plan,
    required this.status,
    required this.buffering,
    required this.retrying,
    required this.stalled,
    required this.segment,
    required this.word,
    required this.position,
    required this.duration,
    required this.durationExact,
    required this.failed,
    this.device = false,
    this.speed = 1,
  });

  final ReadAloudPlan plan;
  final ReadAloudStatus status;
  final bool buffering;
  final bool retrying;
  final bool stalled;
  final int segment;
  final int word;
  final Duration position;
  final Duration duration;
  final bool durationExact;
  final Set<int> failed;
  final bool device;
  final double speed;

  bool get isPaused => status == ReadAloudStatus.paused;
}

class ReadAloudFailure implements Exception {
  const ReadAloudFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class _Stall implements Exception {
  const _Stall(this.segment);

  final int segment;
}

void readAloudTrace(String event, Map<String, Object?> data) {
  debugPrint('[read-aloud] $event $data');
}

class ReadAloudEngine {
  ReadAloudEngine({
    required ik.ElevenLabsTtsClient client,
    TtsAudioCache? cache,
    ReadAloudStore? store,
    ChatTtsBackgroundLease? lease,
    PcmStreamSpeaker? speaker,
    this.maxConcurrentJobs = 3,
    this.firstAudioDeadline = const Duration(seconds: 15),
  }) : _client = client,
       _store = store ?? ReadAloudStore(),
       _lease = lease ?? ChatTtsBackgroundLease(),
       _speaker = speaker ?? PcmStreamSpeaker(logScope: 'gateway/read-aloud') {
    _cache =
        cache ?? TtsAudioCache(protectedKeys: () async => _segKeys.toSet());
  }

  static const String _shapingVersion = 'ra1';
  static const double _defaultMsPerWeight = 62;
  static const int _chunkBytes = kTtsBytesPerSecond ~/ 10;
  static const int _leadBytes = kTtsBytesPerSecond;
  static const int _primeBytes = kTtsBytesPerSecond * 3 ~/ 10;
  static const Duration _tick = Duration(milliseconds: 50);
  static const Duration _saveEvery = Duration(seconds: 5);
  static const int _restartThresholdMs = 1500;

  final ik.ElevenLabsTtsClient _client;
  late final TtsAudioCache _cache;
  final ReadAloudStore _store;
  final ChatTtsBackgroundLease _lease;
  final PcmStreamSpeaker _speaker;
  final int maxConcurrentJobs;
  final Duration firstAudioDeadline;

  void Function()? onStarted;
  void Function(ReadAloudStatus status)? onStatus;
  void Function()? onCompleted;
  void Function(String message, bool heard)? onError;
  void Function(String voice)? onVoiceRejected;
  void Function()? onResumedFromMark;
  void Function(int part, int start, int end)? onWord;

  final ValueNotifier<ReadAloudSnapshot?> snapshot = ValueNotifier(null);

  ReadAloudPlan? _plan;
  String _voice = '';
  String _model = '';
  String _voiceKey = '';
  String? _messageKey;
  List<String> _segKeys = const [];
  final Map<int, int> _cachedBytes = {};
  final Map<int, SegmentJob> _jobs = {};
  final Set<int> _failed = {};
  final Set<Future<void>> _pendingWrites = {};

  int _seg = 0;
  int _offset = 0;
  bool _active = false;
  bool _paused = false;
  bool _running = false;
  bool _waiting = false;
  bool _startedOnce = false;
  bool _audible = false;
  bool _disposed = false;
  int _session = 0;
  int _runId = 0;
  PlaybackClock? _clock;
  Timer? _ticker;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
  Completer<void>? _gate;
  double _msPerWeight = _defaultMsPerWeight;
  double _gain = 1;
  double _speed = 1;
  int _lastWordSeg = -1;
  int _lastWord = -1;
  String? _lastFailure;
  bool _stalled = false;
  Timer? _deadline;
  Completer<void> _halt = Completer<void>();
  DateTime? _playStartedAt;

  AudioSession? _audioSession;
  bool _audioSessionBound = false;
  bool _resumeAfterInterruption = false;
  StreamSubscription<AudioInterruptionEvent>? _interruptSub;
  StreamSubscription<void>? _noisySub;

  bool get isActive => _active;
  bool get isPaused => _active && _paused;
  double get speed => _speed;

  Future<void> setSpeed(double value) async {
    final next = value.clamp(0.5, 3.0).toDouble();
    if ((next - _speed).abs() < 0.001) return;
    _speed = next;
    unawaited(_store.saveSpeed(next));
    if (!_active) return;
    if (_running) {
      final pos = _currentPosition();
      await _jumpTo(pos.segment, pos.offset);
      return;
    }
    _publish();
  }

  Future<void> play({
    required String text,
    required List<String> parts,
    required String voice,
    required String model,
    Map<String, String> pronunciations = const {},
    bool resumeStored = true,
    int? startSegment,
  }) async {
    if (_disposed) return;
    await stop();
    final session = ++_session;
    final plan = ReadAloudPlan.build(
      fullText: text,
      parts: parts,
      pronunciations: pronunciations,
    );
    if (plan.segments.every((s) => s.silent)) {
      onCompleted?.call();
      return;
    }
    _plan = plan;
    _voice = voice;
    _model = model;
    _voiceKey = TtsAudioCache.keyFor(
      text: 'read-aloud',
      voice: voice,
      model: model,
    );
    _messageKey = TtsAudioCache.keyFor(text: text, voice: voice, model: model);
    _segKeys = [
      for (final s in plan.segments)
        TtsAudioCache.keyFor(
          text:
              '$_shapingVersion|${s.endsParagraph ? 'p' : 's'}|${s.spokenText}',
          voice: voice,
          model: model,
        ),
    ];
    unawaited(_cache.prune());
    _cachedBytes.clear();
    _failed.clear();
    _jobs.clear();
    _active = true;
    _paused = false;
    _startedOnce = false;
    _audible = false;
    _lastFailure = null;
    _stalled = false;
    _playStartedAt = DateTime.now();
    _lastWordSeg = -1;
    _lastWord = -1;
    _seg =
        _nextAudible(
          (startSegment ?? 0).clamp(0, plan.segments.length - 1),
          1,
        ) ??
        _nextAudible(0, 1) ??
        0;
    _offset = 0;
    _armDeadline();
    _publish();

    final loads = await Future.wait<Object?>([
      _store.loadRate(_voiceKey),
      _store.loadGain(_voiceKey),
      _store.loadSpeed(),
      if (resumeStored && startSegment == null)
        _store.loadMark(_messageKey!)
      else
        Future.value(),
    ]);
    if (session != _session) return;
    _msPerWeight = loads[0] as double? ?? _defaultMsPerWeight;
    _gain = loads[1] as double? ?? 1;
    _speed = loads[2] as double? ?? _speed;
    final mark = loads[3] as ReadAloudMark?;
    await _probeCache(session, _seg);
    if (session != _session) return;
    if (mark == null && !_cachedBytes.containsKey(_seg)) _startJob(_seg);
    await Future.wait([
      for (var i = 0; i < plan.segments.length; i++)
        if (!plan.segments[i].silent && i != _seg) _probeCache(session, i),
    ]);
    if (session != _session) return;
    if (mark != null) {
      _applyMark(mark);
      if (_seg != (_nextAudible(0, 1) ?? 0) || _offset > 0) {
        onResumedFromMark?.call();
      }
    }
    readAloudTrace('play', {
      'segments': plan.segments.length,
      'cached': _cachedBytes.length,
      'start_segment': _seg,
      'voice': voice.isEmpty ? 'default' : voice,
    });
    _pump();
    final gate = _gate = Completer<void>();
    unawaited(_startRun());
    await gate.future;
  }

  Future<void> _probeCache(int session, int i) async {
    final key = _segKeys[i];
    if (!await _cache.isComplete(key)) return;
    final bytes = await _cache.availableBytes(key);
    if (session != _session || bytes <= 0) return;
    _cachedBytes[i] = bytes;
  }

  Future<void> pause() async {
    _stallRetry?.cancel();
    if (_active && _paused && _stalled) {
      _stalled = false;
      onStatus?.call(ReadAloudStatus.paused);
      _publish();
      unawaited(_lease.release());
      return;
    }
    await _pause(fromInterruption: false);
  }

  Timer? _stallRetry;

  void _scheduleStallRetry() {
    _stallRetry?.cancel();
    _stallRetry = Timer(const Duration(seconds: 3), () {
      if (_active && _paused && _stalled) unawaited(resume());
    });
  }

  Future<void> _pause({required bool fromInterruption}) async {
    if (!_active || _paused) return;
    if (!fromInterruption) _resumeAfterInterruption = false;
    final pos = _currentPosition();
    _seg = pos.segment;
    _offset = pos.offset;
    _paused = true;
    _cancelDeadline();
    await _haltRun();
    _completeGate();
    onStatus?.call(ReadAloudStatus.paused);
    _publish();
    await _saveMark();
    unawaited(_lease.release());
  }

  Future<void> resume() async {
    if (!_active || !_paused) return;
    _resumeAfterInterruption = false;
    _paused = false;
    if (_stalled) _clearFailures();
    final gate = _gate = Completer<void>();
    unawaited(_startRun());
    await gate.future;
  }

  Future<void> seekTo(Duration target) async {
    final plan = _plan;
    if (!_active || plan == null) return;
    var remaining = math.max(0, target.inMilliseconds);
    for (var i = 0; i < plan.segments.length; i++) {
      final ms = _segmentMs(i);
      if (ms == 0) continue;
      if (remaining < ms) {
        await _jumpTo(i, _msToBytes(remaining));
        return;
      }
      remaining -= ms;
    }
    final last = _nextAudible(plan.segments.length - 1, -1);
    if (last == null) return;
    await _jumpTo(last, _msToBytes(math.max(0, _segmentMs(last) - 200)));
  }

  Future<void> skipBy(Duration delta) async {
    final current = snapshot.value?.position ?? Duration.zero;
    await seekTo(current + delta);
  }

  Future<void> skipSegments(int delta) async {
    final plan = _plan;
    if (!_active || plan == null || delta == 0) return;
    final pos = _currentPosition();
    if (delta < 0 && _bytesToMs(pos.offset) > _restartThresholdMs) {
      await _jumpTo(pos.segment, 0);
      return;
    }
    var target = pos.segment;
    for (var step = 0; step < delta.abs(); step++) {
      final next = _nextAudible(target + delta.sign, delta.sign);
      if (next == null) break;
      target = next;
    }
    if (target == pos.segment && delta > 0) return;
    await _jumpTo(target, 0);
  }

  Future<void> playSegment(int segment, {int word = 0}) async {
    final plan = _plan;
    if (!_active || plan == null) return;
    if (segment < 0 || segment >= plan.segments.length) return;
    final s = plan.segments[segment];
    if (s.silent) return;
    final ms = s.msForWord(word, _segmentMs(segment));
    await _jumpTo(segment, _msToBytes(ms), play: true);
  }

  Future<void> stop() async {
    _stallRetry?.cancel();
    if (!_active) return;
    if (_audible) await _saveMark();
    _cancelDeadline();
    _active = false;
    _paused = false;
    _session++;
    await _haltRun();
    final jobs = _jobs.values.toList();
    _jobs.clear();
    for (final job in jobs) {
      unawaited(job.cancel());
    }
    _completeGate();
    _plan = null;
    snapshot.value = null;
    await _lease.release();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _interruptSub?.cancel();
    await _noisySub?.cancel();
    await _speaker.dispose();
    snapshot.dispose();
  }

  Future<void> _haltRun() async {
    _runId++;
    if (!_halt.isCompleted) _halt.complete();
    _waiting = false;
    _stopTicker();
    if (!_running) return;
    _running = false;
    await _speaker.stop(hardFlush: true);
  }

  Future<void> _jumpTo(int seg, int offset, {bool play = false}) async {
    if (!_active) return;
    if (_stalled) {
      _clearFailures();
    } else if (_failed.remove(seg)) {
      final job = _jobs.remove(seg);
      unawaited(job?.cancel());
    }
    final wasRunning = _running;
    await _haltRun();
    _seg = seg;
    _offset = offset - offset % 2;
    _pump();
    if (wasRunning || play) {
      _paused = false;
      _gate = Completer<void>();
      unawaited(_startRun());
      return;
    }
    _publish();
    unawaited(_saveMark());
  }

  Future<void> _startRun() async {
    final plan = _plan;
    if (plan == null || !_active || _disposed) {
      _completeGate();
      return;
    }
    final runId = ++_runId;
    _halt = Completer<void>();
    _running = true;
    _paused = false;
    _stalled = false;
    if (!_audible) _armDeadline();
    final clock = _clock = PlaybackClock(bytesPerSecond: kTtsBytesPerSecond);
    final startSeg = _seg;
    final startOffset = _offset;
    unawaited(_lease.acquire());
    unawaited(_activateAudioSession());
    _startTicker();
    _publish();

    Object? failure;
    try {
      await _speaker.stream(
        _feed(runId, startSeg, startOffset),
        onFirstFrame: () {
          if (runId != _runId) return;
          clock.start();
          _cancelDeadline();
          if (!_audible) {
            final started = _playStartedAt;
            readAloudTrace('first-audio', {
              if (started != null)
                'ms': DateTime.now().difference(started).inMilliseconds,
            });
          }
          _audible = true;
          onStatus?.call(ReadAloudStatus.playing);
          if (!_startedOnce) {
            _startedOnce = true;
            onStarted?.call();
          }
          _completeGate();
          _publish();
        },
      );
    } catch (error, stackTrace) {
      failure = error;
      DebugLogger.error(
        'run-failed',
        scope: 'gateway/read-aloud',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (runId != _runId) return;
    _running = false;
    _waiting = false;
    _stopTicker();
    await _speaker.stop(hardFlush: true);
    if (runId != _runId) return;

    if (failure is _Stall && _audible) {
      _seg = failure.segment;
      _offset = 0;
      _paused = true;
      _stalled = true;
      readAloudTrace('stalled', {
        'segment': failure.segment,
        'reason': _lastFailure ?? '',
      });
      _completeGate();
      _publish();
      await _saveMark();
      _scheduleStallRetry();
      return;
    }

    if (failure != null || !_audible) {
      final message = failure is _Stall || failure == null
          ? _lastFailure ?? 'The gateway returned no audio for this message.'
          : failure.toString();
      await _giveUp(message);
      return;
    }
    final key = _messageKey;
    await Future.wait(_pendingWrites.toList());
    if (runId != _runId) return;
    await _finish();
    if (key != null) await _store.clearMark(key);
    onCompleted?.call();
  }

  Future<void> _giveUp(String message) async {
    final heard = _audible;
    final key = _messageKey;
    readAloudTrace('failed', {'heard': heard, 'reason': message});
    await _finish();
    if (key != null && !heard) await _store.clearMark(key);
    onError?.call(message, heard);
  }

  void _armDeadline() {
    _deadline?.cancel();
    final session = _session;
    _deadline = Timer(firstAudioDeadline, () async {
      if (session != _session || !_active || _audible || _paused) return;
      await _haltRun();
      if (session != _session || !_active) return;
      await _giveUp(
        _lastFailure ??
            'The gateway did not respond within '
                '${firstAudioDeadline.inSeconds} s.',
      );
    });
  }

  void _cancelDeadline() {
    _deadline?.cancel();
    _deadline = null;
  }

  void _clearFailures() {
    _stalled = false;
    for (final i in _failed) {
      final job = _jobs.remove(i);
      unawaited(job?.cancel());
    }
    _failed.clear();
    _lastFailure = null;
  }

  Future<void> _finish() async {
    _cancelDeadline();
    _active = false;
    _paused = false;
    _session++;
    final jobs = _jobs.values.toList();
    _jobs.clear();
    for (final job in jobs) {
      unawaited(job.cancel());
    }
    _completeGate();
    _plan = null;
    snapshot.value = null;
    await _lease.release();
  }

  Stream<Uint8List> _feed(int runId, int startSeg, int startOffset) async* {
    final plan = _plan;
    final clock = _clock;
    final halted = _halt.future;
    if (plan == null || clock == null) return;
    final stretcher = TimeStretcher(
      speed: _speed,
      sampleRate: kTtsSampleRateHz,
    );
    var lastSeg = startSeg;
    var lastAccounted = startOffset;
    var failStreak = 0;
    Future<void> segmentFailed(int i) async {
      failStreak++;
      if (_audible) {
        while (runId == _runId && clock.started && !clock.starved) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        throw _Stall(i);
      }
      if (failStreak >= 2) {
        throw ReadAloudFailure(
          _lastFailure ?? 'The gateway returned no audio for this message.',
        );
      }
    }

    for (var i = startSeg; i < plan.segments.length; i++) {
      if (runId != _runId) return;
      if (plan.segments[i].silent) continue;
      final audio = await _audioFor(i);
      if (runId != _runId) return;
      if (audio == null) {
        await segmentFailed(i);
        continue;
      }
      var offset = i == startSeg ? startOffset : 0;
      offset -= offset % 2;
      var accounted = offset;
      lastSeg = i;
      while (true) {
        if (runId != _runId) return;
        if (offset < audio.length) {
          final end = math.min(audio.length, offset + _chunkBytes);
          final bytes = stretcher.process(audio.bytesFrom(offset, end));
          offset = end;
          if (bytes.isEmpty) continue;
          clock.fed(i, accounted, bytes.length, sourceLength: end - accounted);
          accounted = end;
          lastAccounted = end;
          yield bytes;
          await _pace(runId, clock);
          continue;
        }
        if (audio.done) break;
        _waiting = true;
        await Future.any([audio.waitForChange(), halted]);
        _waiting = false;
      }
      if (audio.failed) {
        if (audio is SegmentJob) {
          _lastFailure = audio.failureReason ?? _lastFailure;
        }
        _failed.add(i);
        _publish();
        await segmentFailed(i);
      } else if (audio.length > 0) {
        failStreak = 0;
      }
    }
    if (runId != _runId) return;
    final tail = stretcher.flush();
    if (tail.isEmpty) return;
    clock.fed(lastSeg, lastAccounted, tail.length, sourceLength: 0);
    yield tail;
  }

  Future<void> _pace(int runId, PlaybackClock clock) async {
    while (runId == _runId) {
      final ahead = clock.started ? clock.bufferedBytes : clock.fedBytes;
      final limit = clock.started ? _leadBytes : _leadBytes + _primeBytes;
      if (ahead <= limit) return;
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  Future<SegmentAudio?> _audioFor(int i) async {
    final job = _jobs[i];
    if (job != null) return job.failed ? null : job;
    if (_cachedBytes.containsKey(i)) {
      try {
        final bytes = await (await _cache.pcmFile(_segKeys[i])).readAsBytes();
        if (bytes.isNotEmpty) return CachedSegmentAudio(bytes);
      } catch (error) {
        DebugLogger.error(
          'cache-read-failed',
          scope: 'gateway/read-aloud',
          error: error,
        );
      }
      _cachedBytes.remove(i);
    }
    if (!_active || _plan == null) return null;
    if (_failed.contains(i)) return null;
    return _startJob(i);
  }

  SegmentJob _startJob(int i) {
    final segment = _plan!.segments[i];
    final session = _session;
    final key = _segKeys[i];
    final gain = _gain;
    final job = SegmentJob(
      client: _client,
      voice: _voice,
      model: _model,
      text: segment.spokenText,
      shaperFactory: () => SegmentShaper(
        gain: gain,
        sampleRate: kTtsSampleRateHz,
        tailKeepMs: segment.endsParagraph ? 500 : 300,
      ),
    );
    _jobs[i] = job;
    unawaited(
      job.start().then((_) {
        final write = _onJobDone(session, i, key, job);
        _pendingWrites.add(write);
        return write.whenComplete(() => _pendingWrites.remove(write));
      }),
    );
    return job;
  }

  Future<void> _onJobDone(
    int session,
    int i,
    String key,
    SegmentJob job,
  ) async {
    final current = session == _session && identical(_jobs[i], job);
    if (current && job.usedDefaultVoice && !job.failed && _voice.isNotEmpty) {
      readAloudTrace('voice-fallback', {'voice': _voice});
      final rejected = _voice;
      _voice = '';
      onVoiceRejected?.call(rejected);
    }
    if (job.failed) {
      if (current) {
        _lastFailure = job.failureReason ?? _lastFailure;
        _failed.add(i);
        _publish();
        _pump();
      }
      return;
    }
    if (!job.complete) {
      if (current) _pump();
      return;
    }
    final weight = current ? _plan!.segments[i].totalWeight : 0;
    final measured = job.measuredGain;
    try {
      final writer = await _cache.openWriter(key: key);
      writer.add(Uint8List.fromList(job.bytes));
      await writer.finish();
      if (session == _session && identical(_jobs[i], job)) {
        _cachedBytes[i] = job.length;
        _jobs.remove(i);
      }
    } catch (error) {
      DebugLogger.error(
        'cache-store-failed',
        scope: 'gateway/read-aloud',
        error: error,
      );
    }
    if (!current) return;
    if (weight > 0) {
      final sample = _bytesToMs(job.length) / weight;
      _msPerWeight = _msPerWeight * 0.8 + sample * 0.2;
      unawaited(_store.saveRate(_voiceKey, _msPerWeight));
    }
    if (measured != null) {
      _gain = _gain * 0.7 + measured * 0.3;
      unawaited(_store.saveGain(_voiceKey, _gain));
    }
    _publish();
    _pump();
  }

  void _pump() {
    final plan = _plan;
    if (plan == null || !_active) return;
    var running = _jobs.values.where((j) => !j.done).length;
    final n = plan.segments.length;
    final cursor = _currentPosition().segment;
    for (var k = 0; k < n && running < maxConcurrentJobs; k++) {
      final i = (cursor + k) % n;
      if (plan.segments[i].silent ||
          _cachedBytes.containsKey(i) ||
          _jobs.containsKey(i) ||
          _failed.contains(i)) {
        continue;
      }
      _startJob(i);
      running++;
    }
  }

  int? _nextAudible(int from, int direction) {
    final plan = _plan;
    if (plan == null) return null;
    for (var i = from; i >= 0 && i < plan.segments.length; i += direction) {
      if (!plan.segments[i].silent) return i;
    }
    return null;
  }

  int _segmentMs(int i) {
    final plan = _plan;
    if (plan == null) return 0;
    final s = plan.segments[i];
    if (s.silent) return 0;
    final cached = _cachedBytes[i];
    if (cached != null) return _bytesToMs(cached);
    final job = _jobs[i];
    final estimate = (s.totalWeight * _msPerWeight).round();
    if (job != null) {
      if (job.done) return _bytesToMs(job.length);
      return math.max(estimate, _bytesToMs(job.length));
    }
    if (_failed.contains(i)) return 0;
    return estimate;
  }

  bool _segmentExact(int i) {
    final s = _plan!.segments[i];
    if (s.silent || _cachedBytes.containsKey(i) || _failed.contains(i)) {
      return true;
    }
    return _jobs[i]?.done ?? false;
  }

  ({int segment, int offset}) _currentPosition() {
    if (_running) {
      final pos = _clock?.position;
      if (pos != null) return pos;
    }
    return (segment: _seg, offset: _offset);
  }

  void _applyMark(ReadAloudMark mark) {
    final plan = _plan!;
    if (mark.part < 0 || mark.part >= plan.parts.length) return;
    final seg = plan.segmentAtPartOffset(mark.part, mark.offset);
    final segment = plan.segments[seg];
    if (segment.silent) return;
    var word = 0;
    for (var w = 0; w < segment.words.length; w++) {
      if (segment.words[w].start <= mark.offset) word = w;
    }
    _seg = seg;
    _offset = _msToBytes(segment.msForWord(word, _segmentMs(seg)));
  }

  Future<void> _saveMark() async {
    final plan = _plan;
    final key = _messageKey;
    if (plan == null || key == null) return;
    _lastSaved = DateTime.now();
    final pos = _currentPosition();
    final segment = plan.segments[pos.segment];
    final total = _totalMs();
    final at = _globalMs(pos);
    if (total <= 0 || at <= total * 0.02 || at >= total * 0.98) {
      await _store.clearMark(key);
      return;
    }
    final word = segment.wordIndexAt(
      _bytesToMs(pos.offset),
      _segmentMs(pos.segment),
    );
    final offset = word < 0 ? segment.start : segment.words[word].start;
    await _store.saveMark(key, (part: segment.partIndex, offset: offset));
  }

  int _totalMs() {
    final plan = _plan;
    if (plan == null) return 0;
    var total = 0;
    for (var i = 0; i < plan.segments.length; i++) {
      total += _segmentMs(i);
    }
    return total;
  }

  int _globalMs(({int segment, int offset}) pos) {
    var before = 0;
    for (var i = 0; i < pos.segment; i++) {
      before += _segmentMs(i);
    }
    return before + math.min(_bytesToMs(pos.offset), _segmentMs(pos.segment));
  }

  void _publish() {
    final plan = _plan;
    if (plan == null || !_active || _disposed) {
      if (!_disposed) snapshot.value = null;
      return;
    }
    final pos = _currentPosition();
    final segMs = _segmentMs(pos.segment);
    final offMs = math.min(_bytesToMs(pos.offset), segMs);
    var exact = true;
    for (var i = 0; i < plan.segments.length && exact; i++) {
      exact = _segmentExact(i);
    }
    final segment = plan.segments[pos.segment];
    final word = segment.wordIndexAt(offMs, segMs);
    final clock = _clock;
    final starved = clock == null || !clock.started || clock.starved;
    final status = _paused && !_stalled
        ? ReadAloudStatus.paused
        : (_running && (clock?.started ?? false))
        ? ReadAloudStatus.playing
        : ReadAloudStatus.loading;
    final job = _jobs[pos.segment];
    snapshot.value = ReadAloudSnapshot(
      plan: plan,
      status: status,
      buffering: _running && _waiting && starved,
      retrying:
          _running && starved && job != null && !job.done && job.attempt > 1,
      stalled: _stalled,
      segment: pos.segment,
      word: word,
      position: Duration(milliseconds: _globalMs(pos)),
      duration: Duration(milliseconds: _totalMs()),
      durationExact: exact,
      failed: Set.unmodifiable(_failed),
      speed: _speed,
    );
    if (pos.segment != _lastWordSeg || word != _lastWord) {
      _lastWordSeg = pos.segment;
      _lastWord = word;
      if (word >= 0) {
        final w = segment.words[word];
        onWord?.call(segment.partIndex, w.start, w.end);
      }
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_tick, (_) {
      if (!_running) return;
      _publish();
      if (_audible && DateTime.now().difference(_lastSaved) >= _saveEvery) {
        unawaited(_saveMark());
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _completeGate() {
    final gate = _gate;
    _gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> _activateAudioSession() async {
    await _bindAudioSession();
    try {
      await _audioSession?.setActive(true);
    } catch (_) {}
  }

  Future<void> _bindAudioSession() async {
    if (_audioSessionBound) return;
    _audioSessionBound = true;
    try {
      final session = await AudioSession.instance;
      _audioSession = session;
      _interruptSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          if (event.type != AudioInterruptionType.pause) return;
          if (_running) {
            _resumeAfterInterruption = true;
            unawaited(_pause(fromInterruption: true));
          }
          return;
        }
        final shouldResume = _resumeAfterInterruption && isPaused;
        _resumeAfterInterruption = false;
        if (shouldResume) unawaited(resume());
      });
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        if (_running) unawaited(pause());
      });
    } catch (error) {
      DebugLogger.log(
        'audio-session-unavailable',
        scope: 'gateway/read-aloud',
        data: {'error': error.toString()},
      );
    }
  }

  static int _bytesToMs(int bytes) => bytes * 1000 ~/ kTtsBytesPerSecond;

  static int _msToBytes(int ms) {
    final raw = ms * kTtsBytesPerSecond ~/ 1000;
    return raw - raw % 2;
  }
}
