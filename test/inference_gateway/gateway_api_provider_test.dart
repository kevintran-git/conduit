import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/api/gateway_api_provider.dart';
import 'package:conduit/inference_gateway/api/gateway_api_service.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TrackingAuthStateManager extends AuthStateManager {
  int authIssueCount = 0;
  int tokenInvalidatedCount = 0;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.authenticated);

  @override
  void onAuthIssue() {
    authIssueCount++;
  }

  @override
  Future<void> onTokenInvalidated() async {
    tokenInvalidatedCount++;
  }
}

void main() {
  test(
    'gatewayApiServiceProviderOverride builds GatewayApiService and wires auth callbacks',
    () async {
      final authNotifier = _TrackingAuthStateManager();
      final workerManager = WorkerManager(maxConcurrentTasks: 1);
      addTearDown(workerManager.dispose);

      const server = ServerConfig(
        id: 'srv-1',
        name: 'Test Server',
        url: 'https://owui.test',
      );

      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWith(gatewayApiServiceProviderOverride),
          reviewerModeProvider.overrideWithValue(false),
          activeServerProvider.overrideWith((_) async => server),
          workerManagerProvider.overrideWithValue(workerManager),
          authStateManagerProvider.overrideWith(() => authNotifier),
        ],
      );
      addTearDown(container.dispose);

      await container.read(activeServerProvider.future);
      final api = container.read(apiServiceProvider);

      check(api).isA<GatewayApiService>();
      api!.onAuthTokenInvalid?.call();
      await api.onTokenInvalidated?.call();

      check(authNotifier.authIssueCount).equals(1);
      check(authNotifier.tokenInvalidatedCount).equals(1);
    },
  );
}
