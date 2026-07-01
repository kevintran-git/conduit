import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/completions/gateway_completions_client.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/tools/gateway_tool_registry.dart';
import 'package:conduit/inference_gateway/transport/gateway_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

class _StubToolRegistry extends GatewayToolRegistry {
  _StubToolRegistry(this._tools);
  final List<ik.ToolSpec> _tools;

  @override
  Future<List<ik.ToolSpec>> buildTools({
    required GatewayConfig config,
    required String? owuiBaseUrl,
    required String? owuiAuthToken,
  }) async => _tools;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(Map<String, dynamic> body) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await _decodeBody(options, requestStream);
    return handler(body);
  }

  Future<Map<String, dynamic>> _decodeBody(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) async {
    if (options.data is String) {
      return jsonDecode(options.data as String) as Map<String, dynamic>;
    }
    final bytes = <int>[];
    await for (final chunk in requestStream ?? const Stream<Uint8List>.empty()) {
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }
}

ResponseBody _sseBody(List<String> frames) => ResponseBody.fromBytes(
  utf8.encode(frames.join()),
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _contentFrame(String text) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    })}\n\n';

const _doneFrame = 'data: [DONE]\n\n';

GatewayClient _gatewayClient(GatewayConfig config) {
  final container = ProviderContainer(
    overrides: [
      gatewayConfigProvider.overrideWith(
        () => _FixedGatewayConfigNotifier(config),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container.read(gatewayClientProvider);
}

Future<String> _collect(Stream<List<int>> byteStream) async {
  final buffer = StringBuffer();
  await for (final chunk in byteStream) {
    buffer.write(utf8.decode(chunk));
  }
  return buffer.toString();
}

void main() {
  final config = GatewayConfig.defaults().copyWith(
    baseUrl: 'https://gateway.test',
    apiKey: 'test-key',
    chatEnabled: true,
  );

  test('streams content deltas as synthesized OpenAI SSE, then [DONE]', () async {
    final adapter = _FakeAdapter(
      (body) => _sseBody([_contentFrame('Hel'), _contentFrame('lo'), _doneFrame]),
    );

    final client = GatewayCompletionsClient(
      _gatewayClient(config),
      inferenceClientFactory: (cfg) =>
          ik.InferenceClient(cfg, dio: Dio()..httpClientAdapter = adapter),
    );

    final session = await client.sendSession(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'gpt-test',
    );

    final raw = await _collect(session.byteStream!);
    check(raw).contains('"content":"Hel"');
    check(raw).contains('"content":"lo"');
    check(raw.trim().endsWith('data: [DONE]')).isTrue();
  });

  test('executes a requested tool and renders its result as a details block', () async {
    var handlerCalls = 0;
    final adapter = _FakeAdapter((body) {
      final messages = body['messages'] as List;
      final hasToolResult = messages.any((m) => (m as Map)['role'] == 'tool');
      if (!hasToolResult) {
        return _sseBody([
          'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_1',
                          'type': 'function',
                          'function': {
                            'name': 'echo',
                            'arguments': '{"text":"hi"}',
                          },
                        },
                      ],
                    },
                  },
                ],
              })}\n\n',
          'data: ${jsonEncode({
                'choices': [
                  {'delta': <String, dynamic>{}, 'finish_reason': 'tool_calls'},
                ],
              })}\n\n',
          _doneFrame,
        ]);
      }
      return _sseBody([_contentFrame('done'), _doneFrame]);
    });

    final client = GatewayCompletionsClient(
      _gatewayClient(config),
      toolRegistry: _StubToolRegistry([
        ik.ToolSpec(
          name: 'echo',
          description: 'echoes the given text',
          parameters: {
            'type': 'object',
            'properties': {
              'text': {'type': 'string'},
            },
          },
          handler: (args) async {
            handlerCalls++;
            return {'result': 'echoed: ${args['text']}'};
          },
        ),
      ]),
      inferenceClientFactory: (cfg) =>
          ik.InferenceClient(cfg, dio: Dio()..httpClientAdapter = adapter),
    );

    final session = await client.sendSession(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      model: 'gpt-test',
    );

    final raw = await _collect(session.byteStream!);
    check(handlerCalls).equals(1);
    check(raw).contains('tool_calls');
    check(raw).contains(r'done=\"true\"');
    check(raw).contains('echoed: hi');
    check(raw).contains('"content":"done"');
  });
}
