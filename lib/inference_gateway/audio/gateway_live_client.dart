import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/utils/debug_logger.dart';
import '../transport/gateway_client.dart';
import 'gemini_function_schema.dart';

sealed class LiveEvent {}

class LiveAudioChunk extends LiveEvent {
  LiveAudioChunk(this.bytes);
  final Uint8List bytes;
}

class LiveInputTranscript extends LiveEvent {
  LiveInputTranscript(this.text);
  final String text;
}

class LiveOutputTranscript extends LiveEvent {
  LiveOutputTranscript(this.text);
  final String text;
}

class LiveInterrupted extends LiveEvent {}

class LiveTurnComplete extends LiveEvent {}

class LiveToolCall extends LiveEvent {
  LiveToolCall(this.calls);
  final List<LiveFunctionCall> calls;
}

class LiveError extends LiveEvent {
  LiveError(this.message);
  final String message;
}

class LiveFunctionCall {
  const LiveFunctionCall({
    required this.id,
    required this.name,
    required this.args,
  });

  final String id;
  final String name;
  final Map<String, dynamic> args;
}

class LiveFunctionResponse {
  const LiveFunctionResponse({
    required this.id,
    required this.name,
    required this.response,
  });

  final String id;
  final String name;
  final Map<String, dynamic> response;
}

// Direct-to-Google client: mint a single-use token through the gateway, then speak the raw BidiGenerateContent wire protocol straight to Google — no proxy hop, no `type`-wrapped envelope (that framing only exists on the gateway's own /ws/gemini-live bridge). [fact]
class GatewayLiveClient {
  GatewayLiveClient({required GatewayClient client}) : _client = client;

  final GatewayClient _client;

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const String _tokenPath = '/v1/gemini-live/token';

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  StreamController<LiveEvent>? _events;
  bool _disposed = false;

  Stream<LiveEvent> get events {
    final e = _events;
    if (e == null) {
      throw StateError('Call start() before reading events.');
    }
    return e.stream;
  }

  Future<void> start({
    String? systemInstruction,
    List<ik.ToolSpec> tools = const [],
  }) async {
    if (_disposed) {
      throw StateError('GatewayLiveClient was disposed');
    }
    if (_events != null) {
      throw StateError('Already started — call stop() first.');
    }
    _events = StreamController<LiveEvent>.broadcast();

    final wssUrl = await _mintToken();
    DebugLogger.log('token-minted', scope: 'gateway/live-ws');

    final socket = await WebSocket.connect(wssUrl).timeout(_connectTimeout);
    final channel = IOWebSocketChannel(socket);
    _channel = channel;
    _channelSub = channel.stream.listen(
      _handleMessage,
      onDone: _handleClose,
      onError: _handleError,
      cancelOnError: false,
    );

    final setup = <String, dynamic>{};
    if (systemInstruction != null && systemInstruction.trim().isNotEmpty) {
      setup['systemInstruction'] = {
        'parts': [
          {'text': systemInstruction},
        ],
      };
    }
    if (tools.isNotEmpty) {
      setup['tools'] = [
        {'functionDeclarations': toGeminiFunctionDeclarations(tools)},
      ];
    }
    channel.sink.add(jsonEncode({'setup': setup}));
  }

  void sendToolResponse(List<LiveFunctionResponse> responses) {
    if (_disposed || responses.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(
        jsonEncode({
          'toolResponse': {
            'functionResponses': [
              for (final r in responses)
                {'id': r.id, 'name': r.name, 'response': r.response},
            ],
          },
        }),
      );
    } catch (_) {}
  }

  Future<String> _mintToken() async {
    final response = await _client.dio.post<dynamic>(_tokenPath);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw StateError('Token mint failed ($status)');
    }
    final data = response.data;
    if (data is! Map) {
      throw StateError('Token mint returned a malformed body');
    }
    final wssUrl = data['wss_url']?.toString();
    if (wssUrl == null || wssUrl.isEmpty) {
      throw StateError('Token mint response missing wss_url');
    }
    return wssUrl;
  }

  void sendAudioChunk(Uint8List pcm) {
    if (_disposed || pcm.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(pcm);
    } catch (_) {}
  }

  Future<void> stop() async {
    await _closeChannel();
    final events = _events;
    _events = null;
    if (events != null && !events.isClosed) await events.close();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }

  // Google's direct BidiGenerateContent endpoint sends JSON as binary WS frames, not text frames — only the gateway's own (now-disabled) proxy used text frames. [fact]
  void _handleMessage(dynamic raw) {
    if (raw is! String && raw is! List<int>) return;
    final Map<String, dynamic> json;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    final events = _events;
    if (events == null || events.isClosed) return;

    final goAway = json['goAway'];
    if (goAway is Map) {
      events.add(LiveError('Session ending: ${goAway['timeLeft'] ?? 'soon'}'));
    }

    final toolCall = json['toolCall'];
    if (toolCall is Map) {
      final functionCalls = toolCall['functionCalls'];
      if (functionCalls is List) {
        final calls = <LiveFunctionCall>[];
        for (final fc in functionCalls) {
          if (fc is! Map) continue;
          final args = fc['args'];
          calls.add(
            LiveFunctionCall(
              id: fc['id']?.toString() ?? '',
              name: fc['name']?.toString() ?? '',
              args: args is Map ? Map<String, dynamic>.from(args) : const {},
            ),
          );
        }
        if (calls.isNotEmpty) events.add(LiveToolCall(calls));
      }
    }

    final serverContent = json['serverContent'];
    if (serverContent is Map) {
      final modelTurn = serverContent['modelTurn'];
      if (modelTurn is Map) {
        final parts = modelTurn['parts'];
        if (parts is List) {
          for (final part in parts) {
            if (part is! Map) continue;
            final inline = part['inlineData'];
            if (inline is Map) {
              final b64 = inline['data']?.toString();
              if (b64 != null && b64.isNotEmpty) {
                events.add(LiveAudioChunk(base64Decode(b64)));
              }
            }
          }
        }
      }
      final inputTranscription = serverContent['inputTranscription'];
      if (inputTranscription is Map) {
        final text = inputTranscription['text']?.toString();
        if (text != null && text.isNotEmpty) events.add(LiveInputTranscript(text));
      }
      final outputTranscription = serverContent['outputTranscription'];
      if (outputTranscription is Map) {
        final text = outputTranscription['text']?.toString();
        if (text != null && text.isNotEmpty) events.add(LiveOutputTranscript(text));
      }
      if (serverContent['interrupted'] == true) {
        events.add(LiveInterrupted());
      }
      if (serverContent['turnComplete'] == true) {
        events.add(LiveTurnComplete());
      }
    }
  }

  void _handleClose() {
    DebugLogger.log('closed', scope: 'gateway/live-ws');
    _channel = null;
    final events = _events;
    if (events != null && !events.isClosed) unawaited(events.close());
  }

  void _handleError(Object error, StackTrace stackTrace) {
    DebugLogger.error(
      'stream-error',
      scope: 'gateway/live-ws',
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
}
