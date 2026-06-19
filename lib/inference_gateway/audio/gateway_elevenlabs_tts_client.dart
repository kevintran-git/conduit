import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';

/// Bidirectional ElevenLabs-compatible TTS over `/v1/text-to-speech/{voice}/
/// stream-input?output_format=pcm`. Mirrors the user's working Python:
///
///     headers = {"Authorization": f"Bearer {TOKEN}"}
///     async with websockets.connect(URL, additional_headers=headers) as ws:
///         await ws.send(json.dumps({"text": "...", "try_trigger_generation": True}))
///         await ws.send(json.dumps({"text": ""}))
///         while True: msg = await ws.recv()   # bytes are PCM
class GatewayElevenLabsTtsClient {
  GatewayElevenLabsTtsClient({required this.config});

  final GatewayConfig config;

  /// One-shot synthesis: open WS, push text, flush, drain PCM, close. Used
  /// by the tap-to-speak path which still expects a `(bytes, mimeType)` blob.
  Future<Uint8List> synthesizeFull({
    required String text,
    required String voice,
    required String model,
  }) async {
    final session = await openSession(voice: voice, model: model);
    try {
      session.appendText(text, triggerGeneration: true);
      session.flush();
      final pcm = <int>[];
      await for (final frame in session.frames) {
        pcm.addAll(frame);
      }
      return Uint8List.fromList(pcm);
    } finally {
      await session.dispose();
    }
  }

  Future<ElevenLabsTtsSession> openSession({
    required String voice,
    required String model,
  }) async {
    final url = _resolveWsUrl(voice: voice, model: model);
    DebugLogger.log(
      'connect',
      scope: 'gateway/tts-ws',
      data: {'url': url, 'has_key': config.apiKey.isNotEmpty},
    );
    final channel = await _connectWithAuth(url);
    if (channel == null) {
      throw StateError('Failed to open TTS WebSocket at $url');
    }
    return ElevenLabsTtsSession._(channel);
  }

  String _resolveWsUrl({required String voice, required String model}) {
    var base = config.baseUrl;
    if (base.startsWith('https://')) {
      base = 'wss://${base.substring('https://'.length)}';
    } else if (base.startsWith('http://')) {
      base = 'ws://${base.substring('http://'.length)}';
    }
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final encodedVoice = Uri.encodeComponent(voice);
    // Match the user's Python reference: only `output_format=pcm` in the
    // query string. `model_id` and the API key go elsewhere (model_id is
    // optional for many gateway voices like "Puck"; auth goes in the
    // Authorization header).
    return '$base/v1/text-to-speech/$encodedVoice/stream-input?output_format=pcm';
  }

  /// dart:io's WebSocket.connect has no default timeout; without this a
  /// gateway that accepts the TCP connection but stalls the upgrade leaves
  /// the future pending forever and an outer dispose() can't reclaim it.
  static const Duration _connectTimeout = Duration(seconds: 10);

  /// Try header auth first (matches the user's Python reference); fall back
  /// to api_key query param if the server rejects the handshake.
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
          scope: 'gateway/tts-ws',
          error: error,
          stackTrace: stackTrace,
        );
      }
      try {
        final separator = url.contains('?') ? '&' : '?';
        final encoded = Uri.encodeQueryComponent(config.apiKey);
        final socket = await WebSocket.connect(
          '$url${separator}api_key=$encoded',
        ).timeout(_connectTimeout);
        return IOWebSocketChannel(socket);
      } catch (error, stackTrace) {
        DebugLogger.error(
          'query-auth-failed',
          scope: 'gateway/tts-ws',
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
        scope: 'gateway/tts-ws',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }
}

/// One open TTS WebSocket; pipe text in, receive PCM frames out.
///
/// Thin protocol pump — no timers, no liveness policy. The [frames] stream
/// stays open as long as the server keeps the WS alive, and closes for
/// exactly one of four reasons:
///
///   1. Server sends `{"isFinal": true}` — clean end-of-utterance
///   2. Server closes the WS — clean end-of-connection
///   3. WS errors — propagated as a stream error
///   4. Caller invokes [dispose] — barge-in, hangup, replaced session
///
/// Critically, idle periods do NOT close the stream. A pause between PCM
/// frames means the server is waiting for more text from us (the LLM is
/// still generating), not that synthesis is finished.
class ElevenLabsTtsSession {
  ElevenLabsTtsSession._(this._channel);

  final WebSocketChannel _channel;
  bool _disposed = false;
  Stream<Uint8List>? _framesCache;

  /// Broadcast so just_audio's proxy can `request()` (and thus `.listen`)
  /// more than once — the platform decoder reconnects during long idle
  /// periods (e.g. while the LLM is still thinking), and a single-subscription
  /// stream would throw on the second listen.
  Stream<Uint8List> get frames =>
      _framesCache ??= _decode().asBroadcastStream();

  void appendText(String text, {bool triggerGeneration = true}) {
    if (_disposed || text.isEmpty) return;
    _channel.sink.add(jsonEncode(<String, dynamic>{
      'text': text,
      if (triggerGeneration) 'try_trigger_generation': true,
    }));
  }

  void flush() {
    if (_disposed) return;
    _channel.sink.add(jsonEncode(<String, dynamic>{'text': ''}));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel.sink.close(ws_status.normalClosure);
    } catch (_) {}
  }

  Stream<Uint8List> _decode() async* {
    var framesEmitted = 0;
    try {
      await for (final raw in _channel.stream) {
        if (_disposed) return;
        if (raw is List<int>) {
          framesEmitted++;
          yield Uint8List.fromList(raw);
          continue;
        }
        if (raw is! String) continue;
        Map<String, dynamic>? json;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) json = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }
        if (json == null) continue;
        final audio = json['audio'];
        if (audio is String && audio.isNotEmpty) {
          framesEmitted++;
          yield base64Decode(audio);
        }
        if (json['isFinal'] == true) {
          DebugLogger.log(
            'is-final',
            scope: 'gateway/tts-ws',
            data: {'frames': framesEmitted},
          );
          return;
        }
      }
    } catch (error, stackTrace) {
      if (_disposed) return;
      DebugLogger.error(
        'stream-error',
        scope: 'gateway/tts-ws',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
