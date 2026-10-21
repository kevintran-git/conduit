import 'dart:async';

import '../../../core/services/background_streaming_handler.dart';

import 'package:conduit_core/utils/debug_logger.dart';

class CallBackgroundLease {
  CallBackgroundLease({String? leaseId, BackgroundStreamingHandler? handler})
    : _leaseId =
          leaseId ??
          'gateway-voice-call-${DateTime.now().microsecondsSinceEpoch}',
      _handler = handler;

  final String _leaseId;
  final BackgroundStreamingHandler? _handler;
  Timer? _keepAliveTimer;
  bool _held = false;

  static const Duration _keepAliveInterval = Duration(minutes: 5);

  static const bool _requiresMicrophone = true;

  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    final bg = _handler ?? BackgroundStreamingHandler.instance;
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
      final bg = _handler ?? BackgroundStreamingHandler.instance;
      unawaited(bg.keepAlive());
    });
  }

  Future<void> release() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_held) return;
    _held = false;
    final bg = _handler ?? BackgroundStreamingHandler.instance;
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
