import 'package:inference_kit/inference_kit.dart' as ik;

import '../../../core/utils/debug_logger.dart';
import '../../audio/gateway_live_client.dart';

Future<List<LiveFunctionResponse>> executeLiveToolCalls(
  List<LiveFunctionCall> calls,
  Map<String, ik.ToolSpec> toolsByName,
) {
  return Future.wait(calls.map((call) => _run(call, toolsByName)));
}

Future<LiveFunctionResponse> _run(
  LiveFunctionCall call,
  Map<String, ik.ToolSpec> toolsByName,
) async {
  final tool = toolsByName[call.name];
  if (tool == null) {
    return LiveFunctionResponse(
      id: call.id,
      name: call.name,
      response: {'error': 'Unknown tool: ${call.name}'},
    );
  }
  try {
    final result = await tool.handler(call.args);
    return LiveFunctionResponse(id: call.id, name: call.name, response: result);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'tool-handler-error',
      scope: 'call/live',
      error: error,
      stackTrace: stackTrace,
    );
    return LiveFunctionResponse(
      id: call.id,
      name: call.name,
      response: {'error': '$error'},
    );
  }
}
