import 'dart:async';

import 'package:flutter/services.dart';

import 'pcm_stream_speaker.dart';

class NativeCallAudioTrack implements PcmAudioSink {
  static const MethodChannel _channel = MethodChannel(
    'app.cogwheel.conduit/call_playback',
  );
  static const EventChannel _events = EventChannel(
    'app.cogwheel.conduit/call_playback/events',
  );

  StreamSubscription<dynamic>? _eventsSub;

  @override
  Future<void> setup({required int sampleRateHz, required int numChannels}) {
    return _channel.invokeMethod<void>('setup', {
      'sampleRate': sampleRateHz,
      'numChannels': numChannels,
    });
  }

  @override
  Future<void> feed(Uint8List bytes) {
    return _channel.invokeMethod<void>('feed', {'buffer': bytes});
  }

  @override
  Future<void> setFeedThreshold(int threshold) {
    return _channel.invokeMethod<void>('setFeedThreshold', {
      'threshold': threshold,
    });
  }

  @override
  void setFeedCallback(void Function(int remainingFrames)? callback) {
    unawaited(_eventsSub?.cancel());
    _eventsSub = null;
    if (callback == null) return;
    _eventsSub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final remaining = (event['remaining_frames'] as num?)?.toInt() ?? 0;
      callback(remaining);
    });
  }

  @override
  bool start() => false;

  @override
  Future<void> release() async {
    await _eventsSub?.cancel();
    _eventsSub = null;
    await _channel.invokeMethod<void>('release');
  }
}
