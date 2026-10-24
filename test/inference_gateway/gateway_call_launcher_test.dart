import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/voice_call/application/call_session.dart';
import 'package:conduit/inference_gateway/voice_call/domain/call_step.dart';
import 'package:conduit/inference_gateway/voice_call/presentation/gateway_call_launcher.dart';
import 'package:conduit/inference_gateway/voice_call/presentation/gateway_call_overlay.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

class _IdleCallSession extends CallSession {
  @override
  CallSessionState build() => const CallSessionState();

  @override
  Future<void> end() async {}
}

final _launcherTestProvider = Provider<GatewayCallLauncher>((ref) {
  return GatewayCallLauncher(ref);
});

void main() {
  testWidgets(
    'inserts GatewayCallOverlay via navigatorKey.currentState.overlay where Overlay.maybeOf(navigatorKey.currentContext) is null',
    (tester) async {
      final router = GoRouter(
        navigatorKey: NavigationService.navigatorKey,
        initialLocation: Routes.chat,
        routes: [
          GoRoute(
            path: Routes.chat,
            builder: (_, _) => const Scaffold(body: SizedBox.expand()),
          ),
        ],
      );
      addTearDown(router.dispose);
      NavigationService.attachRouter(router);

      final config = GatewayConfig.defaults().copyWith(
        baseUrl: 'https://gateway.test',
        apiKey: 'secret-key',
      );

      final container = ProviderContainer(
        overrides: [
          authNavigationStateProvider.overrideWithValue(
            AuthNavigationState.authenticated,
          ),
          gatewayConfigProvider.overrideWith(
            () => _FixedGatewayConfigNotifier(config),
          ),
          selectedModelProvider.overrideWithValue(
            const Model(id: 'gpt-test', name: 'GPT Test'),
          ),
          callSessionProvider.overrideWith(_IdleCallSession.new),
          realtimeCallRouteResolverProvider.overrideWithValue(
            (model, {newChat = false}) async => (
              bridge: null,
              hermes: null,
              block: RealtimeCallBlock.standardChosen,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      check(Overlay.maybeOf(NavigationService.navigatorKey.currentContext!))
          .isNull();
      check(NavigationService.navigatorKey.currentState?.overlay).isNotNull();

      final launchFuture = container
          .read(_launcherTestProvider)
          .launch(startNewConversation: false);
      await tester.pump();
      await tester.pump();

      check(find.byType(GatewayCallOverlay).evaluate()).isNotEmpty();

      await tester.tap(find.bySemanticsLabel('End call'));
      await tester.pump();
      await launchFuture;
    },
  );
}
