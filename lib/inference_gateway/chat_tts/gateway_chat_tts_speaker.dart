import 'dart:async';
import 'dart:typed_data';

import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:pcm_call_audio/pcm_call_audio.dart';

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';
import 'chat_tts_background_lease.dart';
import 'pcm_wav_audio_source.dart';
import 'tts_audio_cache.dart';
import 'tts_position_store.dart';

enum GatewayTtsMode { idle, live, cached }

/// Streaming TTS for the chat surface, in one-shot and incremental flavors.
///
/// Both open an ElevenLabs WS and pump PCM frames through a
/// [PcmStreamSpeaker], so playback starts on the first frame instead of
/// waiting for a full PCM blob. [play] pushes a complete string and resolves
/// when the audio finishes; [startStream]/[feed]/[finishStream] append text as
/// a reply arrives, which is what upstream's voice mode drives through
/// `TextToSpeechService.feedStreamingText`.
///
/// The caching of frames depends on the text, voice, and model.
/// Just_audio plays cached bytes as WAV.
/// Seeking and resuming playback require access to the cache.
/// The TtsPositionStore is responsible for maintaining playback positions.
///
/// Lifecycle callbacks let upstream's `TextToSpeechController` update its
/// "Speaking…" indicator without us touching its event bus.
class GatewayChatTtsSpeaker {
  GatewayChatTtsSpeaker({
    required ik.ElevenLabsTtsClient client,
    required this.config,
    TtsAudioCache? cache,
    TtsPositionStore? positions,
    ChatTtsBackgroundLease? backgroundLease,
  }) : _client = client,
       _speaker = PcmStreamSpeaker(logScope: 'gateway/chat-tts'),
       _cache = cache ?? TtsAudioCache(),
       _positions = positions ?? TtsPositionStore(),
       _lease = backgroundLease ?? ChatTtsBackgroundLease();

  final ik.ElevenLabsTtsClient _client;
  final GatewayConfig config;
  final PcmStreamSpeaker _speaker;
  final TtsAudioCache _cache;
  final TtsPositionStore _positions;
  final ChatTtsBackgroundLease _lease;

  bool _disposed = false;
  ik.ElevenLabsTtsSession? _session;

  ja.AudioPlayer? _player;
  StreamSubscription<Duration>? _playerPositionSub;
  StreamSubscription<ja.ProcessingState>? _playerStateSub;
  Completer<void>? _segmentInterrupt;

  StreamSubscription<Uint8List>? _liveSub;
  StreamController<Uint8List>? _relay;
  TtsCacheWriter? _writer;
  DateTime? _liveStartedAt;
  int _liveBaseBytes = 0;

  GatewayTtsMode _mode = GatewayTtsMode.idle;
  String? _key;
  String? _text;
  String? _voice;
  bool _paused = false;
  bool _stopped = false;
  Duration _lastPosition = Duration.zero;
  Duration _lastSavedPosition = Duration.zero;

  Future<void>? _playback;
  int _fedLength = 0;
  TtsCacheWriter? _streamWriter;
  String _streamText = '';
  void Function()? _onStart;
  void Function()? _onComplete;
  void Function(String message)? _onError;
  void Function()? _streamOnComplete;
  void Function(String message)? _streamOnError;

  GatewayTtsMode get mode => _mode;
  bool get isPaused => _paused;
  bool get isCaching => _liveSub != null;

  Duration get position {
    if (_mode == GatewayTtsMode.cached) {
      final player = _player;
      if (player != null) return player.position;
    }
    if (_mode == GatewayTtsMode.live) {
      final startedAt = _liveStartedAt;
      if (startedAt == null) return ttsBytesToDuration(_liveBaseBytes);
      return ttsBytesToDuration(_liveBaseBytes) +
          DateTime.now().difference(startedAt);
    }
    return _lastPosition;
  }

  Future<Duration?> storedPositionFor(
    String text, {
    String? voiceOverride,
  }) async {
    return _positions.load(_keyFor(text, voiceOverride ?? config.ttsVoice));
  }

  Future<void> play(
    String text, {
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
    String? voiceOverride,
    Duration? startAt,
    bool resumeStored = true,
  }) async {
    if (_disposed) return;
    if (text.trim().isEmpty) {
      onComplete?.call();
      return;
    }
    await stop();

    final voice = voiceOverride ?? config.ttsVoice;
    final key = _keyFor(text, voice);
    _key = key;
    _text = text;
    _voice = voice;
    _stopped = false;
    _paused = false;
    _onStart = onStart;
    _onComplete = onComplete;
    _onError = onError;

    var from = startAt;
    if (from == null && resumeStored) {
      from = await _positions.load(key);
    }
    final available = await _cache.availableBytes(key);
    if (from != null && ttsDurationToBytes(from) >= available) {
      from = Duration.zero;
    }
    _lastPosition = from ?? Duration.zero;
    _lastSavedPosition = _lastPosition;

    DebugLogger.log(
      'play-request',
      scope: 'gateway/chat-tts',
      data: {
        'text_len': text.length,
        'cached_bytes': available,
        'start_ms': (from ?? Duration.zero).inMilliseconds,
      },
    );

    try {
      await _playFrom(key, from ?? Duration.zero);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'play-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      onError?.call(error.toString());
    }
  }

  Future<void> restart(
    String text, {
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
    String? voiceOverride,
  }) async {
    final voice = voiceOverride ?? config.ttsVoice;
    await _positions.clear(_keyFor(text, voice));
    await play(
      text,
      onStart: onStart,
      onComplete: onComplete,
      onError: onError,
      voiceOverride: voiceOverride,
      startAt: Duration.zero,
      resumeStored: false,
    );
  }

  Future<void> _playFrom(String key, Duration from) async {
    await _lease.acquire();
    var cursor = ttsDurationToBytes(from);
    while (!_disposed && !_stopped && !_paused) {
      final available = await _cache.availableBytes(key);
      final complete = await _cache.isComplete(key);
      if (cursor < available) {
        cursor = await _playCachedSegment(key, available, cursor);
        continue;
      }
      if (complete) break;
      if (isCaching) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      await _playLive(key, cursor);
      return;
    }
    if (_disposed || _stopped || _paused) return;
    await _finishNaturally(key);
  }

  Future<int> _playCachedSegment(String key, int available, int cursor) async {
    final file = await _cache.pcmFile(key);
    final source = PcmFileAudioSource(file: file, pcmByteLength: available);
    final player = _ensurePlayer();
    _mode = GatewayTtsMode.cached;

    final done = Completer<void>();
    final interrupt = Completer<void>();
    _segmentInterrupt = interrupt;

    await _playerStateSub?.cancel();
    _playerStateSub = player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed && !done.isCompleted) {
        done.complete();
      }
    });
    await _playerPositionSub?.cancel();
    _playerPositionSub = player.positionStream.listen((value) {
      _lastPosition = value;
      _maybePersistPosition(key, value);
    });

    await player.setAudioSource(
      source,
      initialPosition: ttsBytesToDuration(cursor),
    );
    unawaited(player.play());
    _notifyStart();
    await Future.any<void>([done.future, interrupt.future]);

    final interrupted = interrupt.isCompleted;
    _segmentInterrupt = null;
    final reached = ttsDurationToBytes(player.position);
    if (!interrupted) {
      await player.pause();
    }
    _lastPosition = ttsBytesToDuration(reached);
    if (reached <= cursor) return available;
    return reached > available ? available : reached;
  }

  Future<void> _playLive(String key, int skipBytes) async {
    final text = _text;
    if (text == null) return;

    final session = await _openSession(_voice, textLength: text.length);
    final writer = await _cache.openWriter(key: skipBytes == 0 ? key : null);
    _writer = writer;

    final relay = StreamController<Uint8List>();
    _relay = relay;
    var seen = 0;

    _liveSub = session.frames.listen(
      (chunk) {
        writer.add(chunk);
        final before = seen;
        seen += chunk.length;
        if (relay.isClosed) return;
        if (seen <= skipBytes) return;
        if (before >= skipBytes) {
          relay.add(chunk);
          return;
        }
        relay.add(Uint8List.sublistView(chunk, skipBytes - before));
      },
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'live-frames-failed',
          scope: 'gateway/chat-tts',
          error: error,
          stackTrace: stackTrace,
        );
        if (!relay.isClosed) relay.addError(error, stackTrace);
      },
      onDone: () {
        unawaited(_completeCaching(key));
      },
      cancelOnError: false,
    );

    session.appendText(text, triggerGeneration: true);
    session.flush();

    _mode = GatewayTtsMode.live;
    _liveBaseBytes = skipBytes;
    _liveStartedAt = null;

    try {
      await _speaker.stream(
        relay.stream,
        onFirstFrame: () {
          _liveStartedAt = DateTime.now();
          _notifyStart();
        },
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'live-playback-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      _onError?.call(error.toString());
      return;
    }
    if (_disposed || _stopped || _paused) return;
    await _finishNaturally(key);
  }

  Future<void> _completeCaching(String key) async {
    final writer = _writer;
    _writer = null;
    await _liveSub?.cancel();
    _liveSub = null;
    final relay = _relay;
    if (relay != null && !relay.isClosed) await relay.close();
    if (writer != null) await writer.finish(key: key);
    await _session?.dispose();
    _session = null;
    if (_paused || _stopped) await _lease.release();
  }

  Future<void> _finishNaturally(String key) async {
    await _lease.release();
    _mode = GatewayTtsMode.idle;
    _lastPosition = Duration.zero;
    await _positions.clear(key);
    _onComplete?.call();
  }

  void _notifyStart() {
    final callback = _onStart;
    _onStart = null;
    callback?.call();
  }

  void _maybePersistPosition(String key, Duration value) {
    if ((value - _lastSavedPosition).abs() < const Duration(seconds: 5)) return;
    _lastSavedPosition = value;
    unawaited(_positions.save(key, value));
  }

  ja.AudioPlayer _ensurePlayer() {
    return _player ??= ja.AudioPlayer(handleInterruptions: true);
  }

  String _keyFor(String text, String voice) {
    return TtsAudioCache.keyFor(
      text: text,
      voice: voice,
      model: config.ttsModel,
    );
  }

  /// Opens a session that stays open across [feed] calls. Playback runs in the
  /// background from here on; [finishStream] is what waits for it to drain.
  Future<void> startStream({
    void Function()? onStart,
    void Function()? onComplete,
    void Function(String message)? onError,
    String? voiceOverride,
  }) async {
    if (_disposed) return;
    await stop();
    _fedLength = 0;
    _streamText = '';
    _stopped = false;
    _voice = voiceOverride ?? config.ttsVoice;
    _streamOnComplete = onComplete;
    _streamOnError = onError;
    await _lease.acquire();

    try {
      final session = await _openSession(voiceOverride);
      final writer = await _cache.openWriter();
      _streamWriter = writer;
      _mode = GatewayTtsMode.live;
      _playback = _speaker
          .stream(
            session.frames.map((chunk) {
              writer.add(chunk);
              return chunk;
            }),
            onFirstFrame: onStart,
          )
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'stream-playback-failed',
              scope: 'gateway/chat-tts',
              error: error,
              stackTrace: stackTrace,
            );
            _streamOnError?.call(error.toString());
          });
    } catch (error, stackTrace) {
      DebugLogger.error(
        'stream-open-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      onError?.call(error.toString());
    }
  }

  /// Appends whatever part of [accumulatedText] hasn't been sent yet. Callers
  /// pass the full text so far, matching `TextToSpeechService`'s contract.
  void feed(String accumulatedText) {
    final session = _session;
    if (_disposed || session == null) return;
    if (accumulatedText.length <= _fedLength) return;
    session.appendText(
      accumulatedText.substring(_fedLength),
      triggerGeneration: true,
    );
    _fedLength = accumulatedText.length;
    _streamText = accumulatedText;
  }

  /// Flushes the session and resolves once the queued audio has played out.
  Future<void> finishStream({String? finalText}) async {
    final session = _session;
    if (_disposed || session == null) return;
    if (finalText != null) feed(finalText);
    session.flush();
    try {
      await _playback;
      _streamOnComplete?.call();
    } finally {
      _playback = null;
      _streamOnComplete = null;
      _streamOnError = null;
      _mode = GatewayTtsMode.idle;
      await _lease.release();
      final writer = _streamWriter;
      _streamWriter = null;
      if (writer != null && _streamText.trim().isNotEmpty) {
        await writer.finish(
          key: _keyFor(_streamText, _voice ?? config.ttsVoice),
        );
      } else {
        await writer?.abandon(keepPrefix: false);
      }
      await _session?.dispose();
      _session = null;
    }
  }

  Future<ik.ElevenLabsTtsSession> _openSession(
    String? voiceOverride, {
    int? textLength,
  }) async {
    DebugLogger.log(
      'open-session',
      scope: 'gateway/chat-tts',
      data: {
        'voice': voiceOverride ?? config.ttsVoice,
        'model': config.ttsModel,
        'text_len': ?textLength,
      },
    );
    final session = await _client.openSession(
      voice: voiceOverride ?? config.ttsVoice,
      model: config.ttsModel,
    );
    _session = session;
    return session;
  }

  Future<void> stop() async {
    _stopped = true;
    _paused = false;
    final key = _key;
    final resting = position;
    _interruptSegment();

    _playback = null;
    _fedLength = 0;
    _streamText = '';
    _streamOnComplete = null;
    _streamOnError = null;
    _onStart = null;
    _onComplete = null;
    _onError = null;

    await _playerPositionSub?.cancel();
    _playerPositionSub = null;
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _player?.stop();

    await _liveSub?.cancel();
    _liveSub = null;
    final relay = _relay;
    _relay = null;
    if (relay != null && !relay.isClosed) await relay.close();
    await _writer?.abandon();
    _writer = null;
    await _streamWriter?.abandon(keepPrefix: false);
    _streamWriter = null;

    await _speaker.stop(hardFlush: true);
    await _session?.dispose();
    _session = null;

    _mode = GatewayTtsMode.idle;
    _liveStartedAt = null;
    _liveBaseBytes = 0;
    _lastPosition = resting;
    await _lease.release();
    if (key != null) await _positions.save(key, resting);
  }

  /// Pausing playback causes the WebSocket to continue sending data to the cache.
  Future<void> pause() async {
    if (_disposed || _paused) return;
    if (_mode == GatewayTtsMode.idle) return;
    final key = _key;
    _paused = true;
    _lastPosition = position;
    _interruptSegment();

    if (_mode == GatewayTtsMode.cached) {
      await _player?.pause();
    } else {
      final relay = _relay;
      if (relay != null && !relay.isClosed) await relay.close();
      _relay = null;
      await _speaker.stop(hardFlush: true);
    }
    if (key != null) {
      _lastSavedPosition = _lastPosition;
      await _positions.save(key, _lastPosition);
    }
    if (!isCaching) await _lease.release();
  }

  Future<void> resume() async {
    if (_disposed || !_paused) return;
    final key = _key;
    if (key == null) {
      _paused = false;
      return;
    }
    _paused = false;
    _stopped = false;
    try {
      await _playFrom(key, _lastPosition);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'resume-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
      _onError?.call(error.toString());
    }
  }

  Future<void> seek(Duration target) async {
    if (_disposed) return;
    final key = _key;
    if (key == null) return;
    final clamped = target < Duration.zero ? Duration.zero : target;

    if (_mode == GatewayTtsMode.cached) {
      final available = await _cache.availableBytes(key);
      if (ttsDurationToBytes(clamped) < available) {
        await _player?.seek(clamped);
        _lastPosition = clamped;
        return;
      }
    }

    final wasPaused = _paused;
    await pause();
    _lastPosition = clamped;
    if (wasPaused) return;
    await resume();
  }

  void _interruptSegment() {
    final interrupt = _segmentInterrupt;
    _segmentInterrupt = null;
    if (interrupt != null && !interrupt.isCompleted) interrupt.complete();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _player?.dispose();
    _player = null;
    await _speaker.dispose();
  }
}
