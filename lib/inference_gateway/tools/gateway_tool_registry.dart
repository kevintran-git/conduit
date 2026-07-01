import 'package:dio/dio.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';

class GatewayToolRegistry {
  ik.McpClient? _mcpClient;
  String? _mcpCacheKey;
  List<ik.ToolSpec>? _mcpToolsCache;

  Future<List<ik.ToolSpec>> buildTools({
    required GatewayConfig config,
    required String? owuiBaseUrl,
    required String? owuiAuthToken,
  }) async {
    final tools = <ik.ToolSpec>[];

    if (config.mcpEnabled && config.mcpServerUrl.trim().isNotEmpty) {
      tools.addAll(await _mcpTools(config));
    }

    if (config.statsToolEnabled &&
        (owuiBaseUrl?.isNotEmpty ?? false) &&
        (owuiAuthToken?.isNotEmpty ?? false)) {
      tools.add(_statsTool(baseUrl: owuiBaseUrl!, authToken: owuiAuthToken!));
    }

    return tools;
  }

  Future<List<ik.ToolSpec>> _mcpTools(GatewayConfig config) async {
    final endpoint = config.mcpServerUrl.trim();
    final token = config.mcpBearerToken.trim();
    final cacheKey = '$endpoint|$token';
    final cached = _mcpToolsCache;
    if (cached != null && _mcpCacheKey == cacheKey) return cached;

    final client = ik.McpClient(
      endpoint: endpoint,
      headers: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
      clientName: 'conduit',
      timeout: const Duration(seconds: 90),
    );
    try {
      final specs = await client.toolSpecs();
      _mcpClient?.close();
      _mcpClient = client;
      _mcpCacheKey = cacheKey;
      _mcpToolsCache = specs;
      return specs;
    } catch (error, stackTrace) {
      client.close();
      DebugLogger.error(
        'mcp-tools-unavailable',
        scope: 'gateway/tools',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  ik.ToolSpec _statsTool({required String baseUrl, required String authToken}) {
    final dio = Dio();
    return ik.ToolSpec(
      name: 'get_chat_usage_stats',
      description:
          "Return usage statistics across the user's chats on the Open WebUI server: per-chat message counts, models used, and average response times.",
      parameters: {
        'type': 'object',
        'properties': {
          'page': {'type': 'integer'},
          'items_per_page': {'type': 'integer'},
        },
      },
      handler: (args) async {
        try {
          final response = await dio.get<dynamic>(
            '${_stripTrailingSlash(baseUrl)}/api/v1/chats/stats/usage',
            queryParameters: {
              if (args['page'] != null) 'page': args['page'],
              if (args['items_per_page'] != null)
                'items_per_page': args['items_per_page'],
            },
            options: Options(
              headers: {'Authorization': 'Bearer $authToken'},
              validateStatus: (status) => status != null && status < 600,
            ),
          );
          final status = response.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            return {'error': 'HTTP $status'};
          }
          return {'result': response.data};
        } catch (error) {
          return {'error': '$error'};
        }
      },
    );
  }

  String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  void dispose() => _mcpClient?.close();
}
