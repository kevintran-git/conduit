import 'dart:async';

import '../../../core/services/background_streaming_handler.dart';
import '../../../core/utils/debug_logger.dart';

/// Holds a native background-execution lease for the lifetime of a voice call.
///
/// On Android this stands up the foreground service (with the microphone
/// foreground-service type) so the call keeps running — mic capture, STT WS,
/// and TTS playback — when the app is backgrounded or the screen locks.
/// [WakelockPlus] (held separately by [CallSession]) only keeps the screen
/// awake while we're foreground; this is the piece that survives backgrounding.
///
/// Mirrors upstream's `ChatVoiceModeBackgroundCoordinator` but lives in the
/// gateway so [CallSession] owns its own lifecycle end-to-end. The singleton
/// [BackgroundStreamingHandler] is already initialized at app startup, so we
/// only acquire / keepalive / release a lease here.
///
/// Failures never propagate into the call: a lease that won't start degrades
/// to "the call suspends when backgrounded", it doesn't abort the conversation.
class CallBackgroundLease {
  CallBackgroundLease({String? leaseId})
      : _leaseId = leaseId ??
            'gateway-voice-call-${DateTime.now().microsecondsSinceEpoch}';

  final String _leaseId;
  Timer? _keepAliveTimer;
  bool _held = false;

  /// iOS grants ~30s background tasks that must be refreshed; Android refreshes
  /// the service wake lock. 5 min matches upstream's cadence.
  static const Duration _keepAliveInterval = Duration(minutes: 5);

  /// Every voice call captures the mic for STT, so the lease always declares
  /// the microphone foreground-service type.
  static const bool _requiresMicrophone = true;

  /// Acquire the lease and start the keepalive heartbeat. Safe to await — the
  /// platform calls swallow their own errors.
  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    final bg = BackgroundStreamingHandler.instance;
    // We manage our own audio session (PcmStreamSpeaker + record), so we're not
    // an "external" owner in the iOS sense upstream uses for device-TTS-only
    // calls. No-op on Android.
    await bg.setExternalAudioSessionOwner(!_requiresMicrophone);
    try {
      await bg.startBackgroundExecution(
        [_leaseId],
        requiresMicrophone: _requiresMicrophone,
        kind: BackgroundStreamKind.voice,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-start-failed',
        scope: 'call/bg',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _startKeepAlive();
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(_keepAliveInterval, (_) {
      if (!_held) {
        _keepAliveTimer?.cancel();
        _keepAliveTimer = null;
        return;
      }
      unawaited(BackgroundStreamingHandler.instance.keepAlive());
    });
  }

  /// Cancel the keepalive timer (synchronously) and release the native lease.
  /// Safe to fire-and-forget from teardown — the platform call can take a
  /// moment and we never want it blocking call teardown (Android ANR risk).
  Future<void> release() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_held) return;
    _held = false;
    final bg = BackgroundStreamingHandler.instance;
    try {
      await bg.stopBackgroundExecution([_leaseId]);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-stop-failed',
        scope: 'call/bg',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await bg.setExternalAudioSessionOwner(false);
  }
}
