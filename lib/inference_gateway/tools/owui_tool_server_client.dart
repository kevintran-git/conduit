import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/utils/debug_logger.dart';

class OwuiToolServerConfig {
  const OwuiToolServerConfig({
    required this.selectionKey,
    required this.url,
    required this.path,
    required this.type,
    required this.authType,
    required this.key,
    required this.specType,
    required this.spec,
    required this.enabled,
  });

  factory OwuiToolServerConfig.fromJson(Map<String, dynamic> json, int index) {
    String stringOr(dynamic value, String fallback) {
      final s = value?.toString().trim();
      return (s == null || s.isEmpty) ? fallback : s;
    }

    final config = json['config'];
    final id = json['id']?.toString().trim();

    return OwuiToolServerConfig(
      selectionKey: (id != null && id.isNotEmpty) ? id : index.toString(),
      url: (json['url']?.toString() ?? '').trim(),
      path: (json['path']?.toString() ?? '').trim(),
      type: stringOr(json['type'], 'openapi'),
      authType: stringOr(json['auth_type'], 'bearer'),
      key: json['key']?.toString(),
      specType: stringOr(json['spec_type'], 'url'),
      spec: json['spec']?.toString(),
      enabled: config is Map && config['enable'] == true,
    );
  }

  final String selectionKey;
  final String url;
  final String path;
  final String type;
  final String authType;
  final String? key;
  final String specType;
  final String? spec;
  final bool enabled;

  bool get isMcp => type == 'mcp';

  bool get isCallableAuth =>
      authType == 'bearer' || authType == 'none' || authType == 'session';

  String get specUrl => path.contains('://')
      ? path
      : '$url${path.startsWith('/') ? '' : '/'}$path';

  String? resolveToken(String ownAuthToken) {
    switch (authType) {
      case 'bearer':
        return key;
      case 'session':
        return ownAuthToken;
      case 'none':
      default:
        return null;
    }
  }
}

class OwuiToolServerClient {
  OwuiToolServerClient(this._dio);

  final Dio _dio;

  Future<List<OwuiToolServerConfig>> fetchConfiguredServers({
    required String owuiBaseUrl,
    required String owuiAuthToken,
    required Set<String> selectedServerKeys,
  }) async {
    if (selectedServerKeys.isEmpty) return const [];
    try {
      final response = await _dio.get<dynamic>(
        '${_stripTrailingSlash(owuiBaseUrl)}/api/v1/users/user/settings',
        options: Options(
          headers: {'Authorization': 'Bearer $owuiAuthToken'},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return const [];
      final data = response.data;
      if (data is! Map) return const [];
      final ui = data['ui'];
      if (ui is! Map) return const [];
      final servers = ui['toolServers'];
      if (servers is! List) return const [];

      final parsed = [
        for (var i = 0; i < servers.length; i++)
          if (servers[i] is Map)
            OwuiToolServerConfig.fromJson(
              Map<String, dynamic>.from(servers[i] as Map),
              i,
            ),
      ];

      return parsed
          .where(
            (s) =>
                s.enabled &&
                s.url.isNotEmpty &&
                s.isCallableAuth &&
                selectedServerKeys.contains(s.selectionKey),
          )
          .toList(growable: false);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'owui-tool-servers-unavailable',
        scope: 'gateway/tools',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<List<OwuiToolServerConfig>> fetchAdminToolServerConnections({
    required String owuiBaseUrl,
    required String owuiAuthToken,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        '${_stripTrailingSlash(owuiBaseUrl)}/api/v1/configs/tool_servers',
        options: Options(
          headers: {'Authorization': 'Bearer $owuiAuthToken'},
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return const [];
      final data = response.data;
      if (data is! Map) return const [];
      final connections = data['TOOL_SERVER_CONNECTIONS'];
      if (connections is! List) return const [];

      final parsed = [
        for (var i = 0; i < connections.length; i++)
          if (connections[i] is Map)
            OwuiToolServerConfig.fromJson(
              Map<String, dynamic>.from(connections[i] as Map),
              i,
            ),
      ];

      return parsed
          .where((s) => s.enabled && s.url.isNotEmpty && s.isCallableAuth)
          .toList(growable: false);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'owui-admin-tool-servers-unavailable',
        scope: 'gateway/tools',
        error: error,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  Future<Map<String, dynamic>?> fetchOpenApiSpec(
    OwuiToolServerConfig server, {
    required String? resolvedToken,
  }) async {
    if (server.specType == 'json') {
      final raw = server.spec;
      if (raw == null || raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
      } catch (_) {
        return null;
      }
    }
    try {
      final response = await _dio.get<dynamic>(
        server.specUrl,
        options: Options(
          headers: {
            if (resolvedToken != null && resolvedToken.isNotEmpty)
              'Authorization': 'Bearer $resolvedToken',
          },
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) return null;
      final data = response.data;
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'owui-tool-server-spec-failed',
        scope: 'gateway/tools',
        error: error,
        stackTrace: stackTrace,
        data: {'url': server.specUrl},
      );
      return null;
    }
  }

  String _stripTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
