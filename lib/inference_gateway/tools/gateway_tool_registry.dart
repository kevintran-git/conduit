import 'package:dio/dio.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

import '../../core/utils/debug_logger.dart';
import '../config/gateway_config.dart';
import 'openapi_tool_converter.dart';
import 'owui_tool_server_client.dart';

class GatewayToolRegistry {
  GatewayToolRegistry({OwuiToolServerClient? owuiToolServers})
    : _dio = Dio(),
      _owuiToolServers = owuiToolServers ?? OwuiToolServerClient(Dio());

  static const Duration _cacheTtl = Duration(minutes: 2);

  final Dio _dio;
  final OwuiToolServerClient _owuiToolServers;
  final List<ik.McpClient> _mcpClients = [];

  String? _cacheKey;
  List<ik.ToolSpec>? _cache;
  DateTime? _cachedAt;

  String? _adminCacheKey;
  List<ik.ToolSpec>? _adminCache;
  DateTime? _adminCachedAt;

  Future<List<ik.ToolSpec>> buildTools({
    required GatewayConfig config,
    required String? owuiBaseUrl,
    required String? owuiAuthToken,
    bool includeToolServers = true,
    Set<String> selectedToolServerKeys = const {},
    bool includeAdminToolServers = false,
  }) async {
    final tools = <ik.ToolSpec>[];
    final hasOwuiCreds =
        (owuiBaseUrl?.isNotEmpty ?? false) && (owuiAuthToken?.isNotEmpty ?? false);

    if (hasOwuiCreds && includeToolServers) {
      tools.addAll(
        await _owuiTools(
          baseUrl: owuiBaseUrl!,
          authToken: owuiAuthToken!,
          selectedServerKeys: selectedToolServerKeys,
        ),
      );
    }

    if (hasOwuiCreds && includeAdminToolServers) {
      tools.addAll(
        await _adminOwuiTools(baseUrl: owuiBaseUrl!, authToken: owuiAuthToken!),
      );
    }

    if (config.statsToolEnabled && hasOwuiCreds) {
      tools.add(_statsTool(baseUrl: owuiBaseUrl!, authToken: owuiAuthToken!));
    }

    return tools;
  }

  Future<List<ik.ToolSpec>> _adminOwuiTools({
    required String baseUrl,
    required String authToken,
  }) async {
    final cacheKey = '$baseUrl|$authToken';
    final cachedAt = _adminCachedAt;
    if (_adminCache != null &&
        _adminCacheKey == cacheKey &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return _adminCache!;
    }

    final servers = await _owuiToolServers.fetchAdminToolServerConnections(
      owuiBaseUrl: baseUrl,
      owuiAuthToken: authToken,
    );
    final results = await Future.wait(
      servers.map((server) => _toolsForServer(server, authToken)),
    );
    final tools = results.expand((t) => t).toList(growable: false);

    _adminCacheKey = cacheKey;
    _adminCache = tools;
    _adminCachedAt = DateTime.now();
    return tools;
  }

  Future<List<ik.ToolSpec>> _owuiTools({
    required String baseUrl,
    required String authToken,
    required Set<String> selectedServerKeys,
  }) async {
    final cacheKey =
        '$baseUrl|$authToken|${(selectedServerKeys.toList()..sort()).join(',')}';
    final cachedAt = _cachedAt;
    if (_cache != null &&
        _cacheKey == cacheKey &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _cacheTtl) {
      return _cache!;
    }

    final servers = await _owuiToolServers.fetchConfiguredServers(
      owuiBaseUrl: baseUrl,
      owuiAuthToken: authToken,
      selectedServerKeys: selectedServerKeys,
    );
    final results = await Future.wait(
      servers.map((server) => _toolsForServer(server, authToken)),
    );
    final tools = results.expand((t) => t).toList(growable: false);

    _cacheKey = cacheKey;
    _cache = tools;
    _cachedAt = DateTime.now();
    return tools;
  }

  Future<List<ik.ToolSpec>> _toolsForServer(
    OwuiToolServerConfig server,
    String ownAuthToken,
  ) async {
    final token = server.resolveToken(ownAuthToken);
    try {
      if (server.isMcp) {
        final client = ik.McpClient(
          endpoint: server.specUrl,
          headers: (token == null || token.isEmpty)
              ? const {}
              : {'Authorization': 'Bearer $token'},
          clientName: 'conduit',
          timeout: const Duration(seconds: 90),
        );
        _mcpClients.add(client);
        return await client.toolSpecs();
      }

      final spec = await _owuiToolServers.fetchOpenApiSpec(
        server,
        resolvedToken: token,
      );
      if (spec == null) return const [];
      return buildToolSpecsForOpenApiServer(
        openapi: spec,
        dio: _dio,
        baseUrl: server.url,
        token: token,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'owui-tool-server-unavailable',
        scope: 'gateway/tools',
        error: error,
        stackTrace: stackTrace,
        data: {'url': server.url},
      );
      return const [];
    }
  }

  ik.ToolSpec _statsTool({required String baseUrl, required String authToken}) {
    final dio = _dio;
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

  void dispose() {
    for (final client in _mcpClients) {
      client.close();
    }
    _mcpClients.clear();
  }
}
