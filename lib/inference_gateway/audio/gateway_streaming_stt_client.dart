import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';

/// One transcript event surfaced to consumers.
class StreamingSttEvent {
  StreamingSttEvent({required this.text, required this.isFinal});

  /// Cumulative transcript for the in-flight utterance. On `isFinal: true`
  /// it's the canonical transcription.
  final String text;

  /// True for end-of-utterance transcripts (after `flush` or natural pause).
  final bool isFinal;
}

/// Live STT WebSocket client for `/ws/audio/transcribe` (Chirp 3).
///
/// One WS per utterance. No resume buffer, no reconnects, no audio replay —
/// each call to [start] opens a fresh connection; [stop] tears it down. If
/// the WS dies mid-utterance, the events stream errors and the caller falls
/// back to the silence-only path on the next turn.
///
/// This is deliberately dumb. Earlier iterations kept an unacked PCM ring
/// buffer and replayed it on reconnect, which caused old audio to be
/// re-transcribed and produced ghost utterances. Conversational use doesn't
/// need that — a dropped connection means we missed a word, not the whole
/// turn, and the user can just say it again.
class GatewayStreamingSttClient {
  GatewayStreamingSttClient({
    required this.config,
    List<String>? adaptationPhrases,
  }) : _phrases = adaptationPhrases ?? const [];

  final GatewayConfig config;
  final List<String> _phrases;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamController<StreamingSttEvent>? _events;
  bool _disposed = false;

  /// 16-bit PCM mono @ 16kHz = 32 bytes per ms.
  static const int _bytesPerMs = 32;

  Stream<StreamingSttEvent> get events {
    final e = _events;
    if (e == null) {
      throw StateError('Call start() before reading events.');
    }
    return e.stream;
  }

  bool get isConnected => _channel != null;

  /// Open the WS and start a transcribe session. The returned future resolves
  /// once the WS handshake completes and `{type:'start'}` has been sent.
  Future<void> start() async {
    if (_disposed) {
      throw StateError('GatewayStreamingSttClient was disposed');
    }
    if (_events != null) {
      throw StateError('Already started — call stop() first.');
    }
    _events = StreamController<StreamingSttEvent>.broadcast();
    await _open();
  }

  Future<void> _open() async {
    final wsUrl = _resolveWsUrl();
    DebugLogger.log(
      'connect',
      scope: 'gateway/stt-ws',
      data: {'url': wsUrl, 'has_key': config.apiKey.isNotEmpty},
    );
    final channel = await _connectWithAuth(wsUrl);
    if (channel == null) {
      throw StateError('Could not open STT WebSocket at $wsUrl');
    }

    _channel = channel;
    _channelSub = channel.stream.listen(
      _handleMessage,
      onDone: _handleClose,
      onError: _handleError,
      cancelOnError: false,
    );

    final startMessage = <String, dynamic>{
      'type': 'start',
      if (_phrases.isNotEmpty) 'phrases': _phrases,
    };
    channel.sink.add(jsonEncode(startMessage));
  }

  void sendAudio(Uint8List pcm) {
    if (_disposed || pcm.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(pcm);
    } catch (_) {
      // Drop will surface via _handleClose/_handleError.
    }
  }

  /// End the current utterance and ask the server for the final transcript.
  ///
  /// Empirically the gateway's explicit `{type:'flush'}` is a no-op (the
  /// server only emits finals when its own auto-EOS detector trips on
  /// silence). So we send a short silence pad alongside the flush command,
  /// which reliably triggers EOS within ~300-600ms.
  void flushUtterance({int silencePadMs = 400}) {
    final channel = _channel;
    DebugLogger.log(
      'flush-sent',
      scope: 'gateway/stt-ws',
      data: {'connected': channel != null, 'pad_ms': silencePadMs},
    );
    if (channel == null) return;
    if (silencePadMs > 0) {
      channel.sink.add(Uint8List(silencePadMs * _bytesPerMs));
    }
    channel.sink.add(jsonEncode({'type': 'flush'}));
  }

  /// Tear down the current session. After this returns, [events] is closed.
  /// Call [start] again to begin a new session.
  Future<void> stop() async {
    final channel = _channel;
    if (channel != null) {
      try {
        channel.sink.add(jsonEncode({'type': 'stop'}));
      } catch (_) {}
    }
    await _closeChannel();
    final events = _events;
    _events = null;
    if (events != null && !events.isClosed) await events.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    DebugLogger.log(
      'ws-msg',
      scope: 'gateway/stt-ws',
      data: {
        'type': json['type'],
        if (json['is_final'] != null) 'is_final': json['is_final'],
        if (json['text'] != null)
          'text_len': (json['text'] as Object?).toString().length,
      },
    );

    final events = _events;
    if (events == null || events.isClosed) return;

    switch (json['type']) {
      case 'ready':
        return;
      case 'transcript':
        events.add(
          StreamingSttEvent(
            text: json['text']?.toString() ?? '',
            isFinal: json['is_final'] == true,
          ),
        );
        return;
      case 'utterance':
        events.add(
          StreamingSttEvent(
            text: json['text']?.toString() ?? '',
            isFinal: true,
          ),
        );
        return;
      case 'done':
        return;
    }
  }

  void _handleClose() {
    DebugLogger.log('closed', scope: 'gateway/stt-ws');
    _channel = null;
    final events = _events;
    if (events != null && !events.isClosed) unawaited(events.close());
  }

  void _handleError(Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'stream-error',
      scope: 'gateway/stt-ws',
      error: error,
      stackTrace: stackTrace,
    );
    _channel = null;
    final events = _events;
    if (events != null && !events.isClosed) {
      events.addError(error, stackTrace);
      unawaited(events.close());
    }
  }

  Future<void> _closeChannel() async {
    final sub = _channelSub;
    final channel = _channel;
    _channelSub = null;
    _channel = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
  }

  String _resolveWsUrl() {
    var base = config.baseUrl;
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring('https://'.length)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring('http://'.length)}';
    }
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return '$base/ws/audio/transcribe';
  }

  static const Duration _connectTimeout = Duration(seconds: 10);

  /// Try Authorization header first (matches the user's Python reference and
  /// is the canonical Bearer auth shape). If the handshake is rejected,
  /// retry with the api_key query param the gateway also accepts.
  Future<WebSocketChannel?> _connectWithAuth(String url) async {
    final hasKey = config.apiKey.isNotEmpty;
    if (hasKey) {
      try {
        final socket = await WebSocket.connect(
          url,
          headers: <String, dynamic>{
            'Authorization': 'Bearer ${config.apiKey}',
          },
        ).timeout(_connectTimeout);
        return IOWebSocketChannel(socket);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'header-auth-failed-trying-query',
          scope: 'gateway/stt-ws',
          error: error,
          stackTrace: stackTrace,
        );
      }
      try {
        final encoded = Uri.encodeQueryComponent(config.apiKey);
        final socket =
            await WebSocket.connect('$url?api_key=$encoded').timeout(_connectTimeout);
        return IOWebSocketChannel(socket);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'query-auth-failed',
          scope: 'gateway/stt-ws',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }
    try {
      final socket = await WebSocket.connect(url).timeout(_connectTimeout);
      return IOWebSocketChannel(socket);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'connect-no-auth-failed',
        scope: 'gateway/stt-ws',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}
