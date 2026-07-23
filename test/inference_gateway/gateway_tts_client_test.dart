import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/audio/gateway_elevenlabs_tts_client.dart';
import 'package:conduit/inference_gateway/audio/gateway_tts_client.dart';
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

class _FailingElevenLabsClient extends GatewayElevenLabsTtsClient {
  _FailingElevenLabsClient() : super(config: GatewayConfig.defaults());

  @override
  Future<Uint8List> synthesizeFull({
    required String text,
    required String voice,
    required String model,
  }) {
    throw StateError('ws unavailable in test');
  }
}

class _EmptyElevenLabsClient extends GatewayElevenLabsTtsClient {
  _EmptyElevenLabsClient() : super(config: GatewayConfig.defaults());

  @override
  Future<Uint8List> synthesizeFull({
    required String text,
    required String voice,
    required String model,
  }) async => Uint8List(0);
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

Uint8List _wavHeader() =>
    Uint8List.fromList('RIFF____WAVEfmt '.codeUnits.take(12).toList());

void main() {
  final defaults = GatewayTtsDefaults(model: 'tts-default', voice: 'voice-default');

  test('WS failure falls back to REST and returns the WAV bytes as-is', () async {
    final wav = _wavHeader();
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromBytes(wav, 200, headers: {
        Headers.contentTypeHeader: ['audio/wav'],
      }),
    );
    final client = GatewayTtsClient(
      client: _gatewayClient(adapter),
      elevenlabs: _FailingElevenLabsClient(),
      defaults: defaults,
    );

    final result = await client.synthesize(text: 'hi');

    check(result.mimeType).equals('audio/wav');
    check(result.bytes).deepEquals(wav);
  });

  test('WS returning empty PCM also falls back to REST', () async {
    final wav = _wavHeader();
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromBytes(wav, 200, headers: {
        Headers.contentTypeHeader: ['audio/wav'],
      }),
    );
    final client = GatewayTtsClient(
      client: _gatewayClient(adapter),
      elevenlabs: _EmptyElevenLabsClient(),
      defaults: defaults,
    );

    final result = await client.synthesize(text: 'hi');

    check(result.mimeType).equals('audio/wav');
  });

  test('raw PCM response (no WAV header, l16 content-type) gets wrapped as WAV', () async {
    final pcm = Uint8List.fromList(List.filled(64, 7));
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromBytes(pcm, 200, headers: {
        Headers.contentTypeHeader: ['audio/l16'],
      }),
    );
    final client = GatewayTtsClient(
      client: _gatewayClient(adapter),
      elevenlabs: _FailingElevenLabsClient(),
      defaults: defaults,
    );

    final result = await client.synthesize(text: 'hi');

    check(result.mimeType).equals('audio/wav');
    check(result.bytes.length).isGreaterThan(pcm.length);
    check(result.bytes.sublist(0, 4)).deepEquals('RIFF'.codeUnits);
  });

  test('non-2xx REST response throws GatewayHttpException', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString('bad request', 400),
    );
    final client = GatewayTtsClient(
      client: _gatewayClient(adapter),
      elevenlabs: _FailingElevenLabsClient(),
      defaults: defaults,
    );

    await check(
      client.synthesize(text: 'hi'),
    ).throws<GatewayHttpException>();
  });

  test('falls back to configured defaults when voice/model are omitted', () async {
    final wav = _wavHeader();
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromBytes(wav, 200, headers: {
        Headers.contentTypeHeader: ['audio/wav'],
      }),
    );
    final client = GatewayTtsClient(
      client: _gatewayClient(adapter),
      elevenlabs: _FailingElevenLabsClient(),
      defaults: defaults,
    );

    await client.synthesize(text: 'hi');

    final body = adapter.lastOptions!.data as Map<String, dynamic>;
    check(body['model']).equals('tts-default');
    check(body['voice']).equals('voice-default');
  });
}
