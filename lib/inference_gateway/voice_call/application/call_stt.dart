import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../core/utils/debug_logger.dart';
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

// ===========================================================================
// On-device STT — wraps the speech_to_text package.
// ===========================================================================

/// Wraps the platform STT (Apple / Android speech recognizer). Manages its
/// own mic and VAD — `pauseFor` triggers the platform's end-of-speech
/// detector. In [manualEosOnly] mode `pauseFor` is set to a long ceiling
/// so only an explicit [requestFinal] commits.
class DeviceCallStt implements CallStt {
  DeviceCallStt({required this.pauseFor, required bool manualEosOnly})
      : _manualEosOnly = manualEosOnly;

  /// Auto-EOS silence threshold when [manualEosOnly] is false.
  final Duration pauseFor;

  bool _manualEosOnly;
  @override
  bool get manualEosOnly => _manualEosOnly;
  @override
  set manualEosOnly(bool value) => _manualEosOnly = value;

  final SpeechToText _speech = SpeechToText();
  final StreamController<SttEvent> _events =
      StreamController<SttEvent>.broadcast();
  bool _initialized = false;
  bool _disposed = false;

  static const Duration _manualPauseCeiling = Duration(minutes: 5);

  @override
  Stream<SttEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('DeviceCallStt was disposed');
    if (!_initialized) {
      final ok = await _speech.initialize(
        onError: (e) {
          DebugLogger.warning(
            'device-stt-error',
            scope: 'call/stt',
            data: {'error': e.errorMsg},
          );
        },
      );
      if (!ok || !_speech.isAvailable) {
        throw StateError('On-device speech recognition is not available.');
      }
      _initialized = true;
    }

    await _speech.listen(
      onResult: _onResult,
      pauseFor: _manualEosOnly ? _manualPauseCeiling : pauseFor,
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
        autoPunctuation: true,
        enableHapticFeedback: false,
      ),
    );
  }

  @override
  Future<void> requestFinal() async {
    try {
      // .stop() flushes a finalResult callback even in manual mode.
      await _speech.stop();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.cancel();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    if (!_events.isClosed) await _events.close();
  }

  void _onResult(SpeechRecognitionResult result) {
    if (_disposed || _events.isClosed) return;
    _events.add(
      SttEvent(text: result.recognizedWords, isFinal: result.finalResult),
    );
  }
}

// ===========================================================================
// Gateway STT — owns the mic and the streaming WS to api.kvt.codes.
// ===========================================================================

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
        // 50 ms PCM frames per the gateway's low-latency spec.
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
