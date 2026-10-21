import 'dart:async';

import '../../core/services/background_streaming_handler.dart';

import 'package:conduit_core/utils/debug_logger.dart';

class ChatTtsBackgroundLease {
  ChatTtsBackgroundLease({String? leaseId})
    : _leaseId =
          leaseId ??
          'gateway-chat-tts-${DateTime.now().microsecondsSinceEpoch}';

  final String _leaseId;
  bool _held = false;
  bool _chained = false;
  void Function()? _previousExpiring;
  void Function(int remainingMinutes)? _previousTimeLimit;
  void Function()? _previousKeepAlive;

  bool get isHeld => _held;

  Future<void> acquire() async {
    if (_held) return;
    _held = true;
    final bg = BackgroundStreamingHandler.instance;
    await bg.setExternalAudioSessionOwner(true);
    _chainExpiryHandlers(bg);
    try {
      await bg.startBackgroundExecution([
        _leaseId,
      ], kind: BackgroundStreamKind.chat);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'background-start-failed',
        scope: 'gateway/chat-tts',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _chainExpiryHandlers(BackgroundStreamingHandler bg) {
    if (_chained) return;
    _chained = true;
    _previousExpiring = bg.onBackgroundTaskExpiring;
    _previousTimeLimit = bg.onBackgroundTimeLimitApproaching;
    _previousKeepAlive = bg.onBackgroundKeepAlive;

    bg.onBackgroundTaskExpiring = () {
      _previousExpiring?.call();
      _refresh(bg, 'task-expiring');
    };
    bg.onBackgroundTimeLimitApproaching = (remainingMinutes) {
      _previousTimeLimit?.call(remainingMinutes);
      _refresh(bg, 'time-limit');
    };
    bg.onBackgroundKeepAlive = () {
      _previousKeepAlive?.call();
      _refresh(bg, 'keepalive-tick');
    };
  }

  void _restoreExpiryHandlers(BackgroundStreamingHandler bg) {
    if (!_chained) return;
    _chained = false;
    bg.onBackgroundTaskExpiring = _previousExpiring;
    bg.onBackgroundTimeLimitApproaching = _previousTimeLimit;
    bg.onBackgroundKeepAlive = _previousKeepAlive;
    _previousExpiring = null;
    _previousTimeLimit = null;
    _previousKeepAlive = null;
  }

  void _refresh(BackgroundStreamingHandler bg, String reason) {
    if (!_held) return;
    DebugLogger.log(
      'background-refresh',
      scope: 'gateway/chat-tts',
      data: {'reason': reason},
    );
    unawaited(bg.keepAlive());
  }

  Future<void> release() async {
    if (!_held) return;
    _held = false;
    final bg = BackgroundStreamingHandler.instance;
    _restoreExpiryHandlers(bg);
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
