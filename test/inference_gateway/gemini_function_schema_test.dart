import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/audio/gemini_function_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

void main() {
  test('uppercases known types and recurses into properties/items', () {
    final result = toGeminiSchema({
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'tags': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['name'],
    });

    check(result['type']).equals('OBJECT');
    check((result['properties'] as Map)['name']['type']).equals('STRING');
    check((result['properties'] as Map)['tags']['type']).equals('ARRAY');
    check((result['properties'] as Map)['tags']['items']['type']).equals('STRING');
    check(result['required'] as List).deepEquals(['name']);
  });

  test('falls back to OBJECT when type is missing but properties are present', () {
    final result = toGeminiSchema({
      'properties': {
        'id': {'type': 'string'},
      },
    });

    check(result['type']).equals('OBJECT');
  });

  test('falls back to ARRAY when type is missing but items are present', () {
    final result = toGeminiSchema({
      'items': {'type': 'integer'},
    });

    check(result['type']).equals('ARRAY');
  });

  test('falls back to STRING when type cannot be inferred', () {
    final result = toGeminiSchema(const {'description': 'unresolved ref'});

    check(result['type']).equals('STRING');
  });

  test('every generated function declaration has a type on every schema node', () {
    final tools = [
      ik.ToolSpec(
        name: 'lookup',
        description: 'lookup',
        parameters: const {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'filter': {},
          },
        },
        handler: (args) async => {},
      ),
    ];

    final declarations = toGeminiFunctionDeclarations(tools);
    final parameters = declarations.single['parameters'] as Map;
    final properties = parameters['properties'] as Map;

    check(parameters['type']).equals('OBJECT');
    check(properties['query']['type']).equals('STRING');
    check(properties['filter']['type']).equals('STRING');
  });
}
