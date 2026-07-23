import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state_manager.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/api_service.dart';
import '../../core/services/worker_manager.dart';
import '../router/gateway_router_providers.dart';
import 'gateway_api_service.dart';

/// Override callback for `apiServiceProvider` that constructs a
/// [GatewayApiService] instead of a plain `ApiService`. Wire this into
/// `ProviderScope.overrides` so every call site (UI, services, sync,
/// etc.) transparently gets gateway routing without changes to the
/// upstream provider definition.
///
/// Mirrors the body of `apiServiceProvider` in `app_providers.dart`. If
/// upstream's setup logic changes, update this override to match.
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
