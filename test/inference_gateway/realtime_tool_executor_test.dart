import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/voice_call/application/realtime_tool_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

ik.ToolSpec _tool(
  String name,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler,
) {
  return ik.ToolSpec(
    name: name,
    description: name,
    parameters: const {'type': 'object', 'properties': {}},
    handler: handler,
  );
}

void main() {
  test('routes each call to the matching tool by name', () async {
    final tools = {
      'echo': _tool('echo', (args) async => {'echoed': args['text']}),
    };

    final results = await executeLiveToolCalls([
      ik.LiveFunctionCall(id: 'call-1', name: 'echo', args: {'text': 'hi'}),
    ], tools);

    check(results).length.equals(1);
    check(results.single.id).equals('call-1');
    check(results.single.response['echoed']).equals('hi');
  });

  test(
    'an unknown tool name returns an error response instead of throwing',
    () async {
      final results = await executeLiveToolCalls([
        ik.LiveFunctionCall(id: 'call-1', name: 'missing', args: const {}),
      ], const {});

      check(results.single.response['error']).equals('Unknown tool: missing');
    },
  );

  test(
    'a handler that throws is caught and wrapped as an error response',
    () async {
      final tools = {
        'boom': _tool('boom', (args) async => throw StateError('kaboom')),
      };

      final results = await executeLiveToolCalls([
        ik.LiveFunctionCall(id: 'call-1', name: 'boom', args: const {}),
      ], tools);

      check(results.single.response['error'].toString()).contains('kaboom');
    },
  );

  test('multiple calls run and preserve per-call id/name pairing', () async {
    final tools = {
      'a': _tool('a', (args) async => {'value': 'A'}),
      'b': _tool('b', (args) async => {'value': 'B'}),
    };

    final results = await executeLiveToolCalls([
      ik.LiveFunctionCall(id: '1', name: 'a', args: const {}),
      ik.LiveFunctionCall(id: '2', name: 'b', args: const {}),
    ], tools);

    check(results[0].id).equals('1');
    check(results[0].response['value']).equals('A');
    check(results[1].id).equals('2');
    check(results[1].response['value']).equals('B');
  });
}
