import 'package:checks/checks.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/tools/realtime_selection_guards.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CallActiveNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final _callActiveProvider = NotifierProvider<_CallActiveNotifier, bool>(
  _CallActiveNotifier.new,
);

void main() {
  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        realtimeCallActiveProvider.overrideWith(
          (ref) => ref.watch(_callActiveProvider),
        ),
        selectedToolIdsProvider.overrideWith(GatewayGuardedToolIds.new),
        selectedFilterIdsProvider.overrideWith(GatewayGuardedFilterIds.new),
        selectedTerminalIdProvider.overrideWith(GatewayGuardedTerminalId.new),
      ],
    );
  }

  void startCall(ProviderContainer container) =>
      container.read(_callActiveProvider.notifier).set(true);
  void endCall(ProviderContainer container) =>
      container.read(_callActiveProvider.notifier).set(false);

  test(
    'starting a call hides non-direct tool ids without discarding them',
    () {
      final container = makeContainer();
      container
          .read(selectedToolIdsProvider.notifier)
          .set(['builtin_search', 'direct_server:abc']);

      startCall(container);
      check(container.read(selectedToolIdsProvider)).deepEquals([
        'direct_server:abc',
      ]);

      endCall(container);
      check(container.read(selectedToolIdsProvider)).deepEquals([
        'builtin_search',
        'direct_server:abc',
      ]);
    },
  );

  test('a live call cannot select non-direct tool ids', () {
    final container = makeContainer();
    startCall(container);

    container
        .read(selectedToolIdsProvider.notifier)
        .set(['builtin_search', 'direct_server:abc']);

    check(container.read(selectedToolIdsProvider)).deepEquals([
      'direct_server:abc',
    ]);
  });

  test('starting a call clears filters and restores them once it ends', () {
    final container = makeContainer();
    container.read(selectedFilterIdsProvider.notifier).set(['f1', 'f2']);

    startCall(container);
    check(container.read(selectedFilterIdsProvider)).isEmpty();

    container
        .read(selectedFilterIdsProvider.notifier)
        .toggle('ignored-during-call');
    check(container.read(selectedFilterIdsProvider)).isEmpty();

    endCall(container);
    check(container.read(selectedFilterIdsProvider)).deepEquals(['f1', 'f2']);
  });

  test(
    'starting a call clears the terminal selection and restores it once it ends',
    () {
      final container = makeContainer();
      container.read(selectedTerminalIdProvider.notifier).set('term-1');

      startCall(container);
      check(container.read(selectedTerminalIdProvider)).isNull();

      container.read(selectedTerminalIdProvider.notifier).set('sneaky');
      check(container.read(selectedTerminalIdProvider)).isNull();

      endCall(container);
      check(container.read(selectedTerminalIdProvider)).equals('term-1');
    },
  );
}
