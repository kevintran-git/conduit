import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/voice_call/presentation/gateway_call_launcher.dart';
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer _container({
  Model? model = const Model(id: 'gpt-test', name: 'GPT Test'),
  required Future<RealtimeCallRoute> Function() route,
}) {
  final container = ProviderContainer(
    overrides: [
      appSettingsProvider.overrideWithValue(const AppSettings()),
      selectedModelProvider.overrideWithValue(model),
      realtimeCallRouteResolverProvider.overrideWithValue(
        (model, {newChat = false}) => route(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('calls use realtime when the route resolves', () async {
    final container = _container(
      route: () async => (bridge: null, hermes: null, block: null),
    );
    check(await container.read(gatewayCallsUseRealtimeProvider.future))
        .isTrue();
  });

  test('calls use the gateway when realtime is blocked', () async {
    final container = _container(
      route: () async =>
          (bridge: null, hermes: null, block: RealtimeCallBlock.standardChosen),
    );
    check(await container.read(gatewayCallsUseRealtimeProvider.future))
        .isFalse();
  });

  test('calls use the gateway when the route lookup fails', () async {
    final container = _container(route: () => Future.error(StateError('x')));
    check(await container.read(gatewayCallsUseRealtimeProvider.future))
        .isFalse();
  });

  test('calls use the gateway without a selected model', () async {
    final container = _container(
      model: null,
      route: () async => (bridge: null, hermes: null, block: null),
    );
    check(await container.read(gatewayCallsUseRealtimeProvider.future))
        .isFalse();
  });
}
