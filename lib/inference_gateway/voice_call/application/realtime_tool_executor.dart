import 'package:inference_kit/inference_kit.dart' as ik;

import '../../../core/utils/debug_logger.dart';

Future<List<ik.LiveFunctionResponse>> executeLiveToolCalls(
  List<ik.LiveFunctionCall> calls,
  Map<String, ik.ToolSpec> toolsByName,
) {
  return Future.wait(calls.map((call) => _run(call, toolsByName)));
}

Future<ik.LiveFunctionResponse> _run(
  ik.LiveFunctionCall call,
  Map<String, ik.ToolSpec> toolsByName,
) async {
  final tool = toolsByName[call.name];
  if (tool == null) {
    return ik.LiveFunctionResponse(
      id: call.id,
      name: call.name,
      response: {'error': 'Unknown tool: ${call.name}'},
    );
  }
  try {
    final result = await tool.handler(call.args);
    return ik.LiveFunctionResponse(
      id: call.id,
      name: call.name,
      response: result,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'tool-handler-error',
      scope: 'call/live',
      error: error,
      stackTrace: stackTrace,
    );
    return ik.LiveFunctionResponse(
      id: call.id,
      name: call.name,
      response: {'error': '$error'},
    );
  }
}
