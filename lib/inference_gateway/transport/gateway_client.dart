import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';

/// Dio client pointed at the configured inference gateway, with a Bearer
/// auth interceptor that reads the API key live from the config notifier
/// (so the user can update it without recreating the client).
///
/// Streaming endpoints (chat completions, audio TTS PCM) override
/// `responseType` per-request. The base client deliberately has long
/// timeouts because LLM streams can pause for many seconds without being
/// "stuck".
class GatewayClient {
  GatewayClient({required Ref ref}) : _ref = ref {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: Duration.zero,
        receiveTimeout: Duration.zero,
        validateStatus: (status) => status != null && status < 600,
      ),
    );
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final cfg = _ref.read(gatewayConfigProvider);
          options.baseUrl = _normalizeBaseUrl(cfg.baseUrl);
          if (cfg.apiKey.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${cfg.apiKey}';
          }
          handler.next(options);
        },
      ),
    );
  }

  late final Dio _dio;
  final Ref _ref;

  Dio get dio => _dio;

  GatewayConfig get config => _ref.read(gatewayConfigProvider);

  String _normalizeBaseUrl(String url) {
    if (url.isEmpty) return GatewayConfig.defaultBaseUrl;
    if (url.endsWith('/')) return url.substring(0, url.length - 1);
    return url;
  }
}

final gatewayClientProvider = Provider<GatewayClient>((ref) {
  return GatewayClient(ref: ref);
});
