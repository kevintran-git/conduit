import 'dart:async';

import '../../core/services/background_streaming_handler.dart';
import '../../core/utils/debug_logger.dart';

/// This component maintains a lease for chat background audio while text-to-speech is active.
/// The Android version of this software operates the dataSync foreground service.
/// Audio playback continues even when the application is sent to the background or the screen is locked.
/// Since there is no microphone, the iOS platform is responsible for managing the audio session externally.
/// When lease acquisition fails, playback is never interrupted.
class ChatTtsBackgroundLease {
  ChatTtsBackgroundLease({String? leaseId})
    : _leaseId =
          leaseId ??
          'gateway-chat-tts-${DateTime.now().microsecondsSinceEpoch}';

  final String _leaseId;
  Timer? _keepAliveTimer;
  bool _held = false;

  static const Duration _keepAliveInterval = Duration(minutes: 5);

  bool get isHeld => _held;

  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    final bg = BackgroundStreamingHandler.instance;
    await bg.setExternalAudioSessionOwner(true);
    try {
      await bg.startBackgroundExecution(
        [_leaseId],
        kind: BackgroundStreamKind.chat,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-start-failed',
        scope: 'gateway/chat-tts',
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
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await bg.setExternalAudioSessionOwner(false);
  }
}
