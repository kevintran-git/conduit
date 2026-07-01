import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../features/chat/services/native_stt_service.dart';
import '../../audio/gateway_streaming_stt_client.dart';
import '../../config/gateway_config.dart';

/// Single event surfaced from either STT impl.
class SttEvent {
  const SttEvent({required this.text, required this.isFinal});
  final String text;
  final bool isFinal;
}

/// One STT impl per call. The session never branches on which one is
/// active — it just consumes [events] and calls [requestFinal] when the user
/// taps the mic button.
abstract class CallStt {
  /// Cumulative partial + (eventually) one final event per utterance.
  /// Closes when [stop] / [dispose] is called or the underlying source
  /// terminates.
  Stream<SttEvent> get events;

  /// Open the mic / WS / native recognizer. Resolves once the engine is
  /// ready to receive audio (or throws on permission / connect failure).
  Future<void> start();

  /// Ask the engine to wrap up the current utterance and emit one final
  /// event. The user tapping the mic button in `listening` lands here.
  Future<void> requestFinal();

  /// Stop capturing audio without disposing the engine.
  Future<void> stop();

  Future<void> dispose();

  /// Toggle for "manual-EOS only" mode. When true, server / platform
  /// auto-EOS is suppressed — only [requestFinal] can produce a final
  /// event. Safe to flip mid-listen: gateway path applies immediately
  /// (next `is_final` from the server is demoted to partial); device path
  /// applies on the next [start] (current listen retains its original
  /// `pauseFor`).
  bool get manualEosOnly;
  set manualEosOnly(bool value);
}


class DeviceCallStt implements CallStt {
  DeviceCallStt({required this.pauseFor, required bool manualEosOnly})
      : _manualEosOnly = manualEosOnly;

  final Duration pauseFor;

  bool _manualEosOnly;
  @override
  bool get manualEosOnly => _manualEosOnly;
  @override
  set manualEosOnly(bool value) => _manualEosOnly = value;

  final NativeSttService _stt = NativeSttService();
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  StreamSubscription<NativeSttEvent>? _sttSub;
  Timer? _settle;
  bool _disposed = false;
  bool _stopping = false;

  // NativeSttService accumulation resets on every startListening, so a manual-mode re-arm folds the dying session's text into _committed before _text restarts. [fact]
  String _committed = '';
  String _text = '';

  bool _finalRequested = false;
  bool _turnDone = false;
  bool _restarting = false;

  static const Duration _restartSettle = Duration(milliseconds: 80);

  @override
  Stream<SttEvent> get events => _events.stream;

  String get _combined {
    final c = _committed.trim();
    final t = _text.trim();
    if (c.isEmpty) return t;
    if (t.isEmpty) return c;
    return '$c $t';
  }

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('DeviceCallStt was disposed');
    _committed = '';
    _text = '';
    _finalRequested = false;
    _turnDone = false;
    await _listenOnce();
  }

  Future<void> _listenOnce() async {
    final stream = await _stt.startListening(
      emitPartialResults: true,
      accumulateResults: true,
    );
    _sttSub = stream.listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.warning(
          'device-stt-error',
          scope: 'call/stt',
          data: {'error': error.toString()},
        );
      },
      onDone: _onSessionEnded,
      cancelOnError: false,
    );
  }

  void _onEvent(NativeSttEvent event) {
    if (_disposed || _events.isClosed || _turnDone) return;
    switch (event.type) {
      case 'result':
        final text = event.text;
        if (text == null) return;
        _text = text;
        if (event.isFinal && (_finalRequested || !_manualEosOnly)) {
          _commitFinal();
        } else {
          _emit(_combined, false);
          if (!_manualEosOnly) _armSettle();
        }
      case 'error':
        DebugLogger.warning(
          'device-stt-error',
          scope: 'call/stt',
          data: {'message': event.message, 'code': event.code},
        );
        _commitFinal();
      case 'status':
      case 'done':
        break;
    }
  }

  void _onSessionEnded() {
    if (_disposed || _turnDone || _stopping || _restarting) return;
    if (_manualEosOnly && !_finalRequested) {
      unawaited(_restart());
    } else {
      _commitFinal();
    }
  }

  void _armSettle() {
    _settle?.cancel();
    _settle = Timer(pauseFor, () {
      if (_disposed || _turnDone) return;
      _commitFinal();
    });
  }

  void _commitFinal() {
    if (_turnDone) return;
    _turnDone = true;
    _settle?.cancel();
    _settle = null;
    _emit(_combined.trim(), true);
  }

  @override
  Future<void> requestFinal() async {
    _finalRequested = true;
    _commitFinal();
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _settle?.cancel();
    _settle = null;
    _committed = '';
    _text = '';
    _finalRequested = false;
    _turnDone = false;
    await _sttSub?.cancel();
    _sttSub = null;
    try {
      await _stt.stopListening();
    } catch (_) {}
    _stopping = false;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    if (!_events.isClosed) await _events.close();
  }

  void _emit(String text, bool isFinal) {
    if (_disposed || _events.isClosed) return;
    _events.add(SttEvent(text: text, isFinal: isFinal));
  }

  Future<void> _restart() async {
    if (_disposed || _restarting || _turnDone) return;
    _restarting = true;
    try {
      _committed = _combined;
      _text = '';
      await _sttSub?.cancel();
      _sttSub = null;
      await Future<void>.delayed(_restartSettle);
      if (_disposed || _turnDone) return;
      await _listenOnce();
    } catch (error) {
      DebugLogger.warning(
        'device-stt-restart-failed',
        scope: 'call/stt',
        data: {'error': error.toString()},
      );
      _commitFinal();
    } finally {
      _restarting = false;
    }
  }
}


/// Captures 16 kHz / 16-bit / mono PCM and streams it to the gateway's
/// `/ws/audio/transcribe` endpoint. Server `is_final` events become final
/// SttEvents — unless [manualEosOnly] is set, in which case they're demoted
/// to partials and only [requestFinal] can produce a true final.
///
/// No client-side RMS VAD. The server (Chirp 3) is the EOS authority; RMS
/// can't distinguish speech from road noise and would false-trigger in
/// loud environments.
class GatewayCallStt implements CallStt {
  GatewayCallStt({required this.config, required bool manualEosOnly})
      : _manualEosOnly = manualEosOnly;

  final GatewayConfig config;

  bool _manualEosOnly;
  @override
  bool get manualEosOnly => _manualEosOnly;
  @override
  set manualEosOnly(bool value) => _manualEosOnly = value;

  final AudioRecorder _recorder = AudioRecorder();
  late final GatewayStreamingSttClient _ws =
      GatewayStreamingSttClient(config: config);

  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<StreamingSttEvent>? _wsSub;
  bool _disposed = false;
  bool _capturing = false;

  /// True between [requestFinal] being called and the next `is_final`
  /// event arriving. While set, the next server final is emitted as a real
  /// final even in [manualEosOnly] mode.
  bool _pendingManualFinal = false;

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('GatewayCallStt was disposed');
    final hasMic = await _recorder.hasPermission();
    if (!hasMic) throw StateError('Microphone permission denied.');

    await _ws.start();
    _wsSub = _ws.events.listen(_onWsEvent);

    final pcmStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 1600,
      ),
    );
    _capturing = true;
    _micSub = pcmStream.listen(
      _ws.sendAudio,
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'mic-stream-error',
          scope: 'call/stt',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _capturing = false;
      },
      cancelOnError: false,
    );
  }

  @override
  Future<void> requestFinal() async {
    _pendingManualFinal = true;
    await _pauseMic();
    _ws.flushUtterance(silencePadMs: 300);
  }

  @override
  Future<void> stop() async {
    await _pauseMic();
    _pendingManualFinal = false;
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws.stop();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    try {
      await _recorder.dispose();
    } catch (_) {}
    await _ws.dispose();
    if (!_events.isClosed) await _events.close();
  }

  void _onWsEvent(StreamingSttEvent event) {
    if (_disposed || _events.isClosed) return;
    if (!event.isFinal) {
      _events.add(SttEvent(text: event.text, isFinal: false));
      return;
    }
    final shouldCommit = !_manualEosOnly || _pendingManualFinal;
    _pendingManualFinal = false;
    _events.add(SttEvent(text: event.text, isFinal: shouldCommit));
  }

  Future<void> _pauseMic() async {
    if (!_capturing) return;
    _capturing = false;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
  }
}
