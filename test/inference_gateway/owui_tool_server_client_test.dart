import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/tools/owui_tool_server_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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

Dio _dio(_FakeAdapter adapter) => Dio()..httpClientAdapter = adapter;

Map<String, dynamic> _server({
  String? id,
  String url = 'https://tools.example.com',
  String path = 'openapi.json',
  String? type,
  String? authType,
  String? key,
  bool enable = true,
}) => {
  if (id != null) 'id': id,
  'url': url,
  'path': path,
  if (type != null) 'type': type,
  if (authType != null) 'auth_type': authType,
  if (key != null) 'key': key,
  'config': {'enable': enable},
};

void main() {
  group('OwuiToolServerConfig', () {
    test('defaults type to openapi, auth_type to bearer, spec_type to url', () {
      final config = OwuiToolServerConfig.fromJson(_server(), 0);
      check(config.type).equals('openapi');
      check(config.authType).equals('bearer');
      check(config.specType).equals('url');
    });

    test('selectionKey falls back to index when the server has no id', () {
      final config = OwuiToolServerConfig.fromJson(_server(), 3);
      check(config.selectionKey).equals('3');
    });

    test('selectionKey uses the server id when present', () {
      final config = OwuiToolServerConfig.fromJson(_server(id: 'srv-1'), 3);
      check(config.selectionKey).equals('srv-1');
    });

    test('resolveToken uses the stored key for bearer auth', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(authType: 'bearer', key: 'server-secret'),
        0,
      );
      check(config.resolveToken('own-token')).equals('server-secret');
    });

    test("resolveToken reuses Conduit's own OWUI token for session auth", () {
      final config = OwuiToolServerConfig.fromJson(
        _server(authType: 'session'),
        0,
      );
      check(config.resolveToken('own-token')).equals('own-token');
    });

    test('resolveToken returns null for none auth', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(authType: 'none'),
        0,
      );
      check(config.resolveToken('own-token')).isNull();
    });

    test('resolveToken returns null for oauth auth it cannot replicate', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(authType: 'oauth_2.1'),
        0,
      );
      check(config.resolveToken('own-token')).isNull();
      check(config.isCallableAuth).isFalse();
    });

    test('specUrl joins a bare url and a relative path with one slash', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(url: 'https://tools.example.com', path: 'openapi.json'),
        0,
      );
      check(config.specUrl).equals('https://tools.example.com/openapi.json');
    });

    test('specUrl does not insert a slash when path already has one', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(url: 'https://tools.example.com', path: '/openapi.json'),
        0,
      );
      check(config.specUrl).equals('https://tools.example.com/openapi.json');
    });

    test('specUrl uses path as-is when it is already a full URL', () {
      final config = OwuiToolServerConfig.fromJson(
        _server(path: 'https://elsewhere.example.com/spec.json'),
        0,
      );
      check(config.specUrl).equals('https://elsewhere.example.com/spec.json');
    });

    test('isMcp is true only for type mcp', () {
      check(
        OwuiToolServerConfig.fromJson(_server(type: 'mcp'), 0).isMcp,
      ).isTrue();
      check(
        OwuiToolServerConfig.fromJson(_server(type: 'openapi'), 0).isMcp,
      ).isFalse();
    });
  });

  group('OwuiToolServerClient.fetchConfiguredServers', () {
    test('parses ui.toolServers from the user settings response', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'ui': {
              'toolServers': [_server()],
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'0'},
      );

      check(servers).length.equals(1);
      check(servers.single.url).equals('https://tools.example.com');
      check(adapter.lastOptions!.path)
          .equals('https://owui.example.com/api/v1/users/user/settings');
      check(adapter.lastOptions!.headers['Authorization'])
          .equals('Bearer user-token');
    });

    test('returns empty when no server is selected, without an HTTP call', () async {
      final adapter = _FakeAdapter(
        (options) => throw StateError('should not fetch over HTTP'),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: const {},
      );

      check(servers).isEmpty();
    });

    test('drops servers not present in the selection', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'ui': {
              'toolServers': [_server(id: 'selected'), _server(id: 'other')],
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'selected'},
      );

      check(servers).length.equals(1);
      check(servers.single.selectionKey).equals('selected');
    });

    test('matches a selection by list index when the server has no id', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'ui': {
              'toolServers': [_server(), _server()],
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'1'},
      );

      check(servers).length.equals(1);
      check(servers.single.selectionKey).equals('1');
    });

    test('drops servers disabled in config.enable', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'ui': {
              'toolServers': [_server(enable: false)],
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'0'},
      );

      check(servers).isEmpty();
    });

    test('drops servers whose auth Conduit cannot replicate client-side', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'ui': {
              'toolServers': [_server(authType: 'oauth_2.1_static')],
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'0'},
      );

      check(servers).isEmpty();
    });

    test('returns empty on a non-2xx response instead of throwing', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString('unauthorized', 401),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchConfiguredServers(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
        selectedServerKeys: {'0'},
      );

      check(servers).isEmpty();
    });
  });

  group('OwuiToolServerClient.fetchOpenApiSpec', () {
    test('fetches from specUrl when spec_type is url', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          '{"openapi": "3.0.0", "paths": {}}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));
      final server = OwuiToolServerConfig.fromJson(_server(), 0);

      final spec = await client.fetchOpenApiSpec(server, resolvedToken: 'tok');

      check(spec!['openapi']).equals('3.0.0');
      check(adapter.lastOptions!.path).equals(server.specUrl);
      check(adapter.lastOptions!.headers['Authorization']).equals('Bearer tok');
    });

    test('parses the embedded spec without an HTTP call when spec_type is json', () async {
      final adapter = _FakeAdapter(
        (options) => throw StateError('should not fetch over HTTP'),
      );
      final client = OwuiToolServerClient(_dio(adapter));
      final server = OwuiToolServerConfig.fromJson({
        ..._server(),
        'spec_type': 'json',
        'spec': '{"openapi": "3.0.0", "paths": {}}',
      }, 0);

      final spec = await client.fetchOpenApiSpec(server, resolvedToken: null);

      check(spec!['openapi']).equals('3.0.0');
    });

    test('returns null on a fetch failure instead of throwing', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString('not found', 404),
      );
      final client = OwuiToolServerClient(_dio(adapter));
      final server = OwuiToolServerConfig.fromJson(_server(), 0);

      final spec = await client.fetchOpenApiSpec(server, resolvedToken: null);

      check(spec).isNull();
    });
  });

  group('OwuiToolServerClient.fetchAdminToolServerConnections', () {
    test('parses TOOL_SERVER_CONNECTIONS regardless of selection', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'TOOL_SERVER_CONNECTIONS': [_server(id: 'brain2'), _server(id: 'firecrawl')],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchAdminToolServerConnections(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'admin-token',
      );

      check(servers).length.equals(2);
      check(adapter.lastOptions!.path)
          .equals('https://owui.example.com/api/v1/configs/tool_servers');
      check(adapter.lastOptions!.headers['Authorization'])
          .equals('Bearer admin-token');
    });

    test('drops disabled or auth-incompatible connections', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString(
          jsonEncode({
            'TOOL_SERVER_CONNECTIONS': [
              _server(id: 'disabled', enable: false),
              _server(id: 'oauth', authType: 'oauth_2.1'),
              _server(id: 'ok'),
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchAdminToolServerConnections(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'admin-token',
      );

      check(servers).length.equals(1);
      check(servers.single.selectionKey).equals('ok');
    });

    test('returns empty when the caller lacks admin access instead of throwing', () async {
      final adapter = _FakeAdapter(
        (options) => ResponseBody.fromString('forbidden', 403),
      );
      final client = OwuiToolServerClient(_dio(adapter));

      final servers = await client.fetchAdminToolServerConnections(
        owuiBaseUrl: 'https://owui.example.com',
        owuiAuthToken: 'user-token',
      );

      check(servers).isEmpty();
    });
  });
}
