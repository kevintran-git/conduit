import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import '../router/gateway_router_providers.dart';
import 'gateway_api_service.dart';

///
ApiService? gatewayApiServiceProviderOverride(Ref ref) {
  final reviewerMode = ref.watch(reviewerModeProvider);
  if (reviewerMode) return null;

  final activeServer = ref.watch(activeServerProvider);
  final workerManager = ref.watch(workerManagerProvider);
  final router = ref.read(gatewayInferenceRouterProvider);

  return activeServer.maybeWhen(
    data: (server) {
      if (server == null) return null;

      final apiService = GatewayApiService(
        serverConfig: server,
        workerManager: workerManager,
        authToken: null,
        router: router,
      );

      apiService.setAuthCallbacks(
        onAuthTokenInvalid: () {
          final authManager = ref.read(authStateManagerProvider.notifier);
          authManager.onAuthIssue();
        },
        onTokenInvalidated: () async {
          final authManager = ref.read(authStateManagerProvider.notifier);
          await authManager.onTokenInvalidated();
        },
      );

      apiService.onTokenInvalidated = () async {
        final authManager = ref.read(authStateManagerProvider.notifier);
        await authManager.onTokenInvalidated();
      };
      apiService.onAuthTokenInvalid = () {
        final authManager = ref.read(authStateManagerProvider.notifier);
        authManager.onAuthIssue();
      };

      return apiService;
    },
    orElse: () => null,
  );
}
