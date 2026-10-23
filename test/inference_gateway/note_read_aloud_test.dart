import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/inference_gateway/read_aloud/note_read_aloud.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Calls {
  final List<(String, String)> toggles = [];
  int stops = 0;
}

class _FakeController extends TextToSpeechController {
  _FakeController(this._calls);

  final _Calls _calls;

  @override
  TextToSpeechState build() => const TextToSpeechState();

  @override
  Future<void> toggleForMessage({
    required String messageId,
    required String text,
  }) async {
    _calls.toggles.add((messageId, text));
    state = state.copyWith(
      activeMessageId: messageId,
      status: TtsPlaybackStatus.speaking,
    );
  }

  @override
  Future<void> stop() async {
    _calls.stops++;
    state = const TextToSpeechState();
  }
}

void main() {
  testWidgets('reads the note aloud and stops on the second tap', (
    tester,
  ) async {
    final calls = _Calls();
    late WidgetRef widgetRef;
    final labels = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          textToSpeechControllerProvider.overrideWith(
            () => _FakeController(calls),
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              final items = gatewayNoteMenuItems(ref, noteId: 'n1');
              labels.add((items.single as AdaptivePopupMenuItem<String>).label);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    check(labels.last).equals('Read aloud');

    handleGatewayNoteMenuSelection(
      widgetRef,
      'copy',
      noteId: 'n1',
      markdown: () => 'Body',
    );
    check(calls.toggles).isEmpty();

    handleGatewayNoteMenuSelection(
      widgetRef,
      'gateway-read-aloud',
      noteId: 'n1',
      markdown: () => 'Body',
    );
    await tester.pump();
    check(calls.toggles).deepEquals([('note:n1', 'Body')]);
    check(labels.last).equals('Stop reading');

    handleGatewayNoteMenuSelection(
      widgetRef,
      'gateway-read-aloud',
      noteId: 'n1',
      markdown: () => 'Body',
    );
    await tester.pump();
    check(calls.stops).equals(1);
    check(labels.last).equals('Read aloud');
  });
}
