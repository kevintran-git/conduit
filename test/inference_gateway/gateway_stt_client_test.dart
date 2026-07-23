import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/audio/gateway_stt_client.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/transport/gateway_client.dart';
import 'package:conduit/inference_gateway/transport/gateway_exception.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions options) handler;
  RequestOptions? lastOptions;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return handler(options);
  }
}

GatewayClient _gatewayClient(_FakeAdapter adapter) {
  final container = ProviderContainer(
    overrides: [
      gatewayConfigProvider.overrideWith(
        () => _FixedGatewayConfigNotifier(
          GatewayConfig.defaults().copyWith(baseUrl: 'https://gateway.test'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final client = container.read(gatewayClientProvider);
  client.dio.httpClientAdapter = adapter;
  return client;
}

void main() {
  test('transcribe posts a multipart file and returns the JSON body', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({'text': 'hello world'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final client = GatewaySttClient(_gatewayClient(adapter));

    final result = await client.transcribe(
      audioBytes: Uint8List.fromList([1, 2, 3, 4]),
      fileName: 'clip.wav',
    );

    check(result['text']).equals('hello world');
    check(adapter.lastOptions!.path).equals('/v1/audio/transcriptions');
    check(adapter.lastOptions!.data).isA<FormData>();
  });

  test('throws ArgumentError for empty audio bytes', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString('{}', 200),
    );
    final client = GatewaySttClient(_gatewayClient(adapter));

    await check(
      client.transcribe(audioBytes: Uint8List(0)),
    ).throws<ArgumentError>();
  });

  test('a non-2xx response is surfaced as GatewayHttpException, not returned as data', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString('unauthorized', 401),
    );
    final client = GatewaySttClient(_gatewayClient(adapter));

    await check(
      client.transcribe(audioBytes: Uint8List.fromList([1, 2, 3])),
    ).throws<GatewayHttpException>();
  });

  test('a plain-string response body is wrapped as {text: ...}', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString(
        '"just text"',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final client = GatewaySttClient(_gatewayClient(adapter));

    final result = await client.transcribe(
      audioBytes: Uint8List.fromList([1, 2, 3]),
    );

    check(result['text']).equals('just text');
  });

  test('infers mime type from the file extension', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({'text': 'ok'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final client = GatewaySttClient(_gatewayClient(adapter));

    await client.transcribe(
      audioBytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'clip.mp3',
    );

    final form = adapter.lastOptions!.data as FormData;
    final filePart = form.files.single.value;
    check(filePart.contentType?.mimeType).equals('audio/mpeg');
  });
}
