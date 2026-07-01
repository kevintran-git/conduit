import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' as dio;
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:uuid/uuid.dart';

import '../../core/models/model.dart';
import '../../core/services/chat_completion_transport.dart';
import '../../core/services/semantic_message_builder.dart';
import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';
import '../tools/gateway_tool_registry.dart';
import '../transport/gateway_client.dart';
import '../transport/gateway_exception.dart';

// sendSession's byte stream is synthesized OpenAI SSE so parseOpenWebUIStream and details-block rendering need no changes. [fact]
class GatewayCompletionsClient {
  GatewayCompletionsClient(
    this._client, {
    GatewayToolRegistry? toolRegistry,
    String? Function()? owuiBaseUrl,
    String? Function()? owuiAuthToken,
    ik.InferenceClient Function(ik.InferenceConfig config)? inferenceClientFactory,
  }) : _toolRegistry = toolRegistry ?? GatewayToolRegistry(),
       _owuiBaseUrl = owuiBaseUrl ?? (() => null),
       _owuiAuthToken = owuiAuthToken ?? (() => null),
       _inferenceClientFactory = inferenceClientFactory ?? ik.InferenceClient.new;

  static const _uuid = Uuid();

  final GatewayClient _client;
  final GatewayToolRegistry _toolRegistry;
  final String? Function() _owuiBaseUrl;
  final String? Function() _owuiAuthToken;
  final ik.InferenceClient Function(ik.InferenceConfig config) _inferenceClientFactory;

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
        path: '/chat/completions',
        statusCode: 0,
        body: 'no messages to send (all roles were stripped during sanitization)',
      );
    }

    final cancelToken = dio.CancelToken();
    final controller = StreamController<List<int>>();
    var closed = false;
    void addFrame(String frame) {
      if (closed || controller.isClosed) return;
      controller.add(utf8.encode(frame));
    }

    unawaited(() async {
      try {
        await _run(
          sanitized: sanitized,
          model: model,
          temperature: temperature,
          maxTokens: maxTokens,
          cancelToken: cancelToken,
          addFrame: addFrame,
        );
      } catch (error, stackTrace) {
        if (!cancelToken.isCancelled) {
          DebugLogger.error(
            'tool-loop-error',
            scope: 'gateway/completions',
            error: error,
            stackTrace: stackTrace,
          );
          addFrame(_sseErrorFrame('$error'));
        }
      } finally {
        addFrame('data: [DONE]\n\n');
        closed = true;
        await controller.close();
      }
    }());

    return ChatCompletionSession.httpStream(
      messageId: messageId,
      conversationId: conversationId,
      byteStream: controller.stream,
      abort: () async {
        if (!cancelToken.isCancelled) cancelToken.cancel('User cancelled');
      },
    );
  }

  Future<void> _run({
    required List<Map<String, dynamic>> sanitized,
    required String model,
    required double? temperature,
    required int? maxTokens,
    required dio.CancelToken cancelToken,
    required void Function(String frame) addFrame,
  }) async {
    final gatewayConfig = _client.config;
    final inferenceClient = _inferenceClientFactory(
      ik.InferenceConfig(
        baseUrl: '${_normalizeBaseUrl(gatewayConfig.baseUrl)}/v1',
        apiKey: gatewayConfig.apiKey,
        model: model,
      ),
    );

    final tools = await _toolRegistry.buildTools(
      config: gatewayConfig,
      owuiBaseUrl: _owuiBaseUrl(),
      owuiAuthToken: _owuiAuthToken(),
    );

    DebugLogger.log(
      'send',
      scope: 'gateway/completions',
      data: {
        'model': model,
        'message_count': sanitized.length,
        'last_role': sanitized.last['role'],
        'tool_count': tools.length,
      },
    );

    final messages = [for (final m in sanitized) ik.Message.raw(m)];

    var emittedTextLength = 0;
    var emittedThinkingLength = 0;
    var emittedInvocationCount = 0;

    void handleProgress(ik.AgentProgress progress) {
      if (progress.thinking.length > emittedThinkingLength) {
        addFrame(
          _sseReasoningFrame(
            progress.thinking.substring(emittedThinkingLength),
          ),
        );
        emittedThinkingLength = progress.thinking.length;
      }
      if (progress.text.length > emittedTextLength) {
        addFrame(_sseContentFrame(progress.text.substring(emittedTextLength)));
        emittedTextLength = progress.text.length;
      }
      if (progress.invocations.length > emittedInvocationCount) {
        for (var i = emittedInvocationCount; i < progress.invocations.length; i++) {
          addFrame(_sseContentFrame('\n${_toolCallMarkup(i, progress.invocations[i])}\n'));
        }
        emittedInvocationCount = progress.invocations.length;
      }
    }

    await _runToolLoopWithResume(
      client: inferenceClient,
      messages: messages,
      tools: tools,
      temperature: temperature,
      maxTokens: maxTokens,
      cancelToken: cancelToken,
      onProgress: handleProgress,
    );
  }

  /// `runToolLoop` retries a stream only pre-first-byte; a drop mid-generation
  /// is resumed here by re-issuing with the partial answer appended as an
  /// assistant turn and asking the model to continue.
  Future<void> _runToolLoopWithResume({
    required ik.InferenceClient client,
    required List<ik.Message> messages,
    required List<ik.ToolSpec> tools,
    required double? temperature,
    required int? maxTokens,
    required dio.CancelToken cancelToken,
    required void Function(ik.AgentProgress) onProgress,
    int maxResumes = 2,
  }) async {
    var history = messages;
    var attempt = 0;
    var lastText = '';
    while (true) {
      try {
        await ik.runToolLoop(
          client: client,
          messages: history,
          tools: tools,
          extraBody: temperature == null ? null : {'temperature': temperature},
          maxTokens: maxTokens,
          cancelToken: cancelToken,
          onProgress: (progress) {
            lastText = progress.text;
            onProgress(progress);
          },
        );
        return;
      } catch (error) {
        if (cancelToken.isCancelled) rethrow;
        if (attempt >= maxResumes || lastText.trim().isEmpty) rethrow;
        attempt++;
        DebugLogger.log(
          'resume',
          scope: 'gateway/completions',
          data: {'attempt': attempt, 'partial_chars': lastText.length},
        );
        history = [...messages, ik.Message.assistant(lastText)];
      }
    }
  }

  String _toolCallMarkup(int index, ik.ToolInvocation invocation) {
    return renderSemanticMessageBlocks([
      SemanticDetailsBlock.toolCall(
        id: 'tool-$index',
        name: invocation.name,
        arguments: invocation.arguments,
        done: true,
        result: invocation.isError
            ? invocation.result['error']
            : invocation.result['result'],
      ),
    ]);
  }

  String _sseContentFrame(String text) {
    if (text.isEmpty) return '';
    return 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        })}\n\n';
  }

  String _sseReasoningFrame(String text) {
    if (text.isEmpty) return '';
    return 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'reasoning_content': text},
            },
          ],
        })}\n\n';
  }

  String _sseErrorFrame(String message) =>
      'data: ${jsonEncode({
            'error': {'message': message},
          })}\n\n';

  String _normalizeBaseUrl(String url) {
    if (url.isEmpty) return GatewayConfig.defaultBaseUrl;
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
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
      } catch (_) {}
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
      // A blank assistant placeholder (no tool calls attached) 400s some gateways. [fact]
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
      // Some OpenAI-compatible gateways reject a 1-element text-part list. [fact]
      if (parts.length == 1 && parts.first['type'] == 'text') {
        return parts.first['text'];
      }
      return parts;
    }
    return content.toString();
  }
}
