import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/tools/openapi_tool_converter.dart';
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

const _spec = {
  'openapi': '3.0.0',
  'paths': {
    '/items/{itemId}': {
      'get': {
        'operationId': 'get_item',
        'summary': 'Fetch an item by id',
        'parameters': [
          {
            'name': 'itemId',
            'in': 'path',
            'required': true,
            'schema': {'type': 'string'},
          },
          {
            'name': 'verbose',
            'in': 'query',
            'schema': {'type': 'boolean'},
          },
        ],
      },
    },
    '/items': {
      'post': {
        'operationId': 'create_item',
        'description': 'Create a new item',
        'requestBody': {
          'content': {
            'application/json': {
              'schema': {r'$ref': '#/components/schemas/NewItem'},
            },
          },
        },
      },
    },
  },
  'components': {
    'schemas': {
      'NewItem': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'quantity': {'type': 'integer'},
        },
        'required': ['name'],
      },
    },
  },
};

void main() {
  test('extracts one tool per operationId with a merged parameter schema', () {
    final tools = buildToolSpecsForOpenApiServer(
      openapi: _spec,
      dio: Dio(),
      baseUrl: 'https://tools.example.com',
      token: null,
    );

    check(tools).length.equals(2);

    final getItem = tools.firstWhere((t) => t.name == 'get_item');
    check(getItem.description).equals('Fetch an item by id');
    final getItemProps = getItem.parameters['properties'] as Map;
    check(getItemProps.keys.toSet()).deepEquals({'itemId', 'verbose'});
    check(getItem.parameters['required'] as List).deepEquals(['itemId']);

    final createItem = tools.firstWhere((t) => t.name == 'create_item');
    check(createItem.description).equals('Create a new item');
    final createItemProps = createItem.parameters['properties'] as Map;
    check(createItemProps.keys.toSet()).deepEquals({'name', 'quantity'});
    check(createItem.parameters['required'] as List).deepEquals(['name']);
  });

  test('handler for a GET operation templates the path and appends query params', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({'id': 'abc123'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final tools = buildToolSpecsForOpenApiServer(
      openapi: _spec,
      dio: dio,
      baseUrl: 'https://tools.example.com',
      token: 'secret-token',
    );
    final getItem = tools.firstWhere((t) => t.name == 'get_item');

    final result = await getItem.handler({'itemId': 'abc123', 'verbose': true});

    check(result['id']).equals('abc123');
    check(adapter.lastOptions!.method).equals('GET');
    check(adapter.lastOptions!.path).equals('https://tools.example.com/items/abc123');
    check(adapter.lastOptions!.queryParameters['verbose']).equals(true);
    check(adapter.lastOptions!.headers['Authorization']).equals('Bearer secret-token');
  });

  test('handler for a POST operation sends the args as the JSON body', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString(
        jsonEncode({'created': true}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final tools = buildToolSpecsForOpenApiServer(
      openapi: _spec,
      dio: dio,
      baseUrl: 'https://tools.example.com',
      token: null,
    );
    final createItem = tools.firstWhere((t) => t.name == 'create_item');

    final result = await createItem.handler({'name': 'widget', 'quantity': 3});

    check(result['created']).equals(true);
    check(adapter.lastOptions!.method).equals('POST');
    check(adapter.lastOptions!.path).equals('https://tools.example.com/items');
    check(adapter.lastOptions!.data as Map)
        .deepEquals({'name': 'widget', 'quantity': 3});
    check(adapter.lastOptions!.headers.containsKey('Authorization')).isFalse();
  });

  test('a non-2xx response is surfaced as an error result, not a thrown exception', () async {
    final adapter = _FakeAdapter(
      (options) => ResponseBody.fromString('server exploded', 500),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final tools = buildToolSpecsForOpenApiServer(
      openapi: _spec,
      dio: dio,
      baseUrl: 'https://tools.example.com',
      token: null,
    );
    final getItem = tools.firstWhere((t) => t.name == 'get_item');

    final result = await getItem.handler({'itemId': 'x'});

    check(result['error'] as String).contains('500');
  });

  test('ignores path entries with no operationId', () {
    final tools = buildToolSpecsForOpenApiServer(
      openapi: const {
        'openapi': '3.0.0',
        'paths': {
          '/no-id': {
            'get': {'summary': 'no operationId here'},
          },
        },
      },
      dio: Dio(),
      baseUrl: 'https://tools.example.com',
      token: null,
    );

    check(tools).isEmpty();
  });
}
