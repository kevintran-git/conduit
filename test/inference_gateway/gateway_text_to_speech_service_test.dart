import 'package:checks/checks.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/inference_gateway/chat_tts/gateway_text_to_speech_service.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit_core/voice/voice_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class _FakeWakelock extends WakelockPlusMacOSPlugin {
  final List<bool> toggles = <bool>[];

  @override
  Future<void> toggle({required bool enable}) async {
    toggles.add(enable);
  }
}

class _FixedVoiceModeController extends ChatVoiceModeController {
  _FixedVoiceModeController(this._snapshot);
  final ChatVoiceModeSnapshot _snapshot;

  @override
  ChatVoiceModeSnapshot build() => _snapshot;
}

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

final _testTtsProvider = Provider<GatewayTextToSpeechService>((ref) {
  return GatewayTextToSpeechService(ref: ref);
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late var previousWakelock = wakelockPlusPlatformInstance;
  late _FakeWakelock fakeWakelock;

  setUp(() {
    previousWakelock = wakelockPlusPlatformInstance;
    fakeWakelock = _FakeWakelock();
    wakelockPlusPlatformInstance = fakeWakelock;
  });

  tearDown(() {
    wakelockPlusPlatformInstance = previousWakelock;
  });

  test('does not disable wakelock when a voice call is active', () async {
    final activeConfig = GatewayConfig.defaults().copyWith(
      baseUrl: 'https://gateway.test',
      apiKey: 'secret-key',
      ttsEnabled: true,
    );

    final activeCallContainer = ProviderContainer(
      overrides: [
        gatewayConfigProvider.overrideWith(
          () => _FixedGatewayConfigNotifier(activeConfig),
        ),
        chatVoiceModeControllerProvider.overrideWith(
          () => _FixedVoiceModeController(
            const ChatVoiceModeSnapshot(phase: ChatVoiceModePhase.listening),
          ),
        ),
      ],
    );
    addTearDown(activeCallContainer.dispose);

    await activeCallContainer.read(_testTtsProvider).stopStreamingTts();
    check(fakeWakelock.toggles).isEmpty();

    final idleCallContainer = ProviderContainer(
      overrides: [
        gatewayConfigProvider.overrideWith(
          () => _FixedGatewayConfigNotifier(activeConfig),
        ),
        chatVoiceModeControllerProvider.overrideWith(
          () => _FixedVoiceModeController(const ChatVoiceModeSnapshot()),
        ),
      ],
    );
    addTearDown(idleCallContainer.dispose);

    await idleCallContainer.read(_testTtsProvider).stopStreamingTts();
    check(fakeWakelock.toggles).deepEquals(<bool>[false]);
  });
}
