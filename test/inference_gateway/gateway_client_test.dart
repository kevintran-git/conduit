import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/transport/gateway_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

class _CapturingAdapter implements HttpClientAdapter {
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
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

({GatewayClient client, _CapturingAdapter adapter, ProviderContainer container})
_gatewayClient(GatewayConfig config) {
  final container = ProviderContainer(
    overrides: [
      gatewayConfigProvider.overrideWith(
        () => _FixedGatewayConfigNotifier(config),
      ),
    ],
  );
  addTearDown(container.dispose);
  final client = container.read(gatewayClientProvider);
  final adapter = _CapturingAdapter();
  client.dio.httpClientAdapter = adapter;
  return (client: client, adapter: adapter, container: container);
}

void main() {
  test('injects Authorization header when an API key is configured', () async {
    final env = _gatewayClient(
      GatewayConfig.defaults().copyWith(
        baseUrl: 'https://gateway.test',
        apiKey: 'secret-key',
      ),
    );

    await env.client.dio.get<void>('/v1/models');

    check(env.adapter.lastOptions!.headers['Authorization'])
        .equals('Bearer secret-key');
  });

  test('omits Authorization header when no API key is configured', () async {
    final env = _gatewayClient(
      GatewayConfig.defaults().copyWith(baseUrl: 'https://gateway.test', apiKey: ''),
    );

    await env.client.dio.get<void>('/v1/models');

    check(env.adapter.lastOptions!.headers.containsKey('Authorization'))
        .isFalse();
  });

  test('strips a trailing slash from the configured base URL', () async {
    final env = _gatewayClient(
      GatewayConfig.defaults().copyWith(baseUrl: 'https://gateway.test/'),
    );

    await env.client.dio.get<void>('/v1/models');

    check(env.adapter.lastOptions!.baseUrl).equals('https://gateway.test');
  });

  test('falls back to the default base URL when none is configured', () async {
    final env = _gatewayClient(GatewayConfig.defaults().copyWith(baseUrl: ''));

    await env.client.dio.get<void>('/v1/models');

    check(env.adapter.lastOptions!.baseUrl).equals(GatewayConfig.defaultBaseUrl);
  });

  test('reads the API key live, so updates apply without recreating the client', () async {
    final env = _gatewayClient(
      GatewayConfig.defaults().copyWith(baseUrl: 'https://gateway.test', apiKey: 'first'),
    );

    await env.client.dio.get<void>('/v1/models');
    check(env.adapter.lastOptions!.headers['Authorization']).equals('Bearer first');

    env.container.read(gatewayConfigProvider.notifier).state =
        env.container.read(gatewayConfigProvider).copyWith(apiKey: 'second');

    await env.client.dio.get<void>('/v1/models');
    check(env.adapter.lastOptions!.headers['Authorization']).equals('Bearer second');
  });
}
