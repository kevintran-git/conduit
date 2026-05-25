import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/model.dart';
import '../../core/services/chat_completion_transport.dart';
import '../../core/utils/debug_logger.dart';
import '../transport/gateway_client.dart';
import '../transport/gateway_exception.dart';
import 'reasoning_tag_splitter.dart';

/// Talks to the gateway's OpenAI-compatible chat completion + models
/// endpoints. The byte stream returned by [sendSession] is plain OpenAI SSE,
/// which `parseOpenWebUIStream` already consumes (it reads
/// `choices[0].delta.content`).
class GatewayCompletionsClient {
  GatewayCompletionsClient(this._client);

  static const _uuid = Uuid();
  static const _path = '/v1/chat/completions';

  final GatewayClient _client;

  Future<ChatCompletionSession> sendSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? responseMessageId,
    double? temperature,
    int? maxTokens,
  }) async {
    final messageId =
        (responseMessageId != null && responseMessageId.isNotEmpty)
        ? responseMessageId
        : _uuid.v4();

    final sanitized = _sanitizeMessages(messages);
    if (sanitized.isEmpty) {
      throw GatewayHttpException(
        path: _path,
        statusCode: 0,
        body: 'no messages to send (all roles were stripped during sanitization)',
      );
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': sanitized,
      'stream': true,
      'temperature': ?temperature,
      'max_tokens': ?maxTokens,
    };

    DebugLogger.log(
      'send',
      scope: 'gateway/completions',
      data: {
        'model': model,
        'message_count': sanitized.length,
        'last_role': sanitized.last['role'],
      },
    );

    final cancelToken = CancelToken();
    Response<ResponseBody> response;
    try {
      response = await _client.dio.post<ResponseBody>(
        _path,
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          sendTimeout: Duration.zero,
          receiveTimeout: Duration.zero,
          headers: const {
            'accept': 'text/event-stream',
            'content-type': 'application/json',
          },
          validateStatus: (status) => status != null && status < 600,
        ),
        cancelToken: cancelToken,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'transport-error',
        scope: 'gateway/completions',
        error: error,
        stackTrace: stackTrace,
      );
      throw GatewayTransportException(path: _path, cause: error);
    }

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final responseBody = await _drain(response.data);
      DebugLogger.error(
        'http-error',
        scope: 'gateway/completions',
        data: {'status': status, 'body': responseBody},
      );
      throw GatewayHttpException(
        path: _path,
        statusCode: status,
        body: responseBody,
      );
    }

    final stream = response.data?.stream ?? const Stream<List<int>>.empty();
    // Reroute inline reasoning tags (`<think>...</think>`, etc.) into
    // `delta.reasoning_content` so the streaming-helper renders them as the
    // collapsible thinking widget instead of mixing them into the visible
    // assistant content. Without this, raw gateway output reads tags out
    // loud over TTS and folds them back into chat history on the next turn.
    final rewritten = splitReasoningTagsInSseStream(stream);

    return ChatCompletionSession.httpStream(
      messageId: messageId,
      conversationId: conversationId,
      byteStream: rewritten,
      abort: () async {
        if (!cancelToken.isCancelled) {
          cancelToken.cancel('User cancelled');
        }
      },
    );
  }

  Future<List<Model>> listChatModels() async {
    return _listFiltered((m) => m['type'] == null);
  }

  Future<List<Map<String, dynamic>>> listTtsModels() async {
    final raw = await _listRaw();
    return raw.where((m) => m['type'] == 'tts').toList();
  }

  Future<List<Map<String, dynamic>>> listSttModels() async {
    final raw = await _listRaw();
    return raw.where((m) => m['type'] == 'stt').toList();
  }

  Future<List<Map<String, dynamic>>> _listRaw() async {
    final response = await _client.dio.get<dynamic>('/v1/models');
    final payload = response.data;
    if (payload is Map && payload['data'] is List) {
      return (payload['data'] as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    if (payload is List) {
      return payload
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    }
    return const [];
  }

  Future<List<Model>> _listFiltered(
    bool Function(Map<String, dynamic>) keep,
  ) async {
    final raw = await _listRaw();
    final models = <Model>[];
    for (final entry in raw) {
      if (!keep(entry)) continue;
      try {
        models.add(Model.fromJson(entry));
      } catch (_) {
        // Skip malformed entries.
      }
    }
    return models;
  }

  /// Hard-strips every Conduit message down to the fields OpenAI accepts.
  /// Conduit messages carry OWUI-specific metadata (id, timestamp, files,
  /// info, model, sources, etc.) — the gateway will 400 if those leak in,
  /// or if `content` is `null` (e.g. an empty assistant placeholder).
  List<Map<String, dynamic>> _sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    const allowedRoles = {'user', 'assistant', 'system', 'tool', 'developer'};
    final out = <Map<String, dynamic>>[];
    for (final raw in messages) {
      final role = (raw['role'] ?? 'user').toString().toLowerCase();
      if (!allowedRoles.contains(role)) continue;

      final content = _sanitizeContent(raw['content']);
      if (content == null) continue;
      // An empty string is OK for OpenAI assistant messages (e.g. tool calls),
      // but skip totally-empty assistant placeholders — they confuse the
      // server and we don't have tool calls to attach.
      if (content is String && content.isEmpty && role == 'assistant') continue;

      out.add(<String, dynamic>{'role': role, 'content': content});
    }
    return out;
  }

  /// Normalize a Conduit content value to OpenAI-compatible shape:
  /// - String → kept verbatim
  /// - List of parts → each part filtered to `{type: 'text'|'image_url', ...}`
  /// - null / other → returns null (caller drops the message)
  dynamic _sanitizeContent(dynamic content) {
    if (content == null) return null;
    if (content is String) return content;
    if (content is List) {
      final parts = <Map<String, dynamic>>[];
      for (final item in content) {
        if (item is! Map) continue;
        final type = item['type']?.toString();
        if (type == 'text') {
          final text = item['text']?.toString();
          if (text != null && text.isNotEmpty) {
            parts.add({'type': 'text', 'text': text});
          }
        } else if (type == 'image_url') {
          final urlField = item['image_url'];
          if (urlField is Map && urlField['url'] is String) {
            parts.add({
              'type': 'image_url',
              'image_url': {'url': urlField['url']},
            });
          } else if (urlField is String) {
            parts.add({
              'type': 'image_url',
              'image_url': {'url': urlField},
            });
          }
        }
      }
      if (parts.isEmpty) return null;
      // If the only part is a text part, collapse to a plain string — some
      // OpenAI-compatible gateways are stricter when content is a 1-element
      // list of `text` parts.
      if (parts.length == 1 && parts.first['type'] == 'text') {
        return parts.first['text'];
      }
      return parts;
    }
    // Fallback: stringify whatever else got passed.
    return content.toString();
  }

  Future<String> _drain(ResponseBody? body) async {
    if (body == null) return '';
    final buffer = <int>[];
    await for (final chunk in body.stream) {
      buffer.addAll(chunk);
      if (buffer.length > 4096) break;
    }
    try {
      return utf8.decode(buffer, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(buffer);
    }
  }
}
