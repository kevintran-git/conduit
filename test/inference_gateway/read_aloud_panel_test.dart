import 'package:conduit/inference_gateway/chat_tts/gateway_text_to_speech_service.dart';
import 'package:conduit/inference_gateway/read_aloud/presentation/read_aloud_panel.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_engine.dart';
import 'package:conduit/inference_gateway/read_aloud/read_aloud_plan.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _serviceProvider = Provider<GatewayTextToSpeechService>(
  (ref) => GatewayTextToSpeechService(ref: ref),
);

ReadAloudPlan _plan(int paragraphs, int sentencesPerParagraph) {
  final parts = <String>[];
  final text = StringBuffer();
  for (var p = 0; p < paragraphs; p++) {
    if (p > 0) text.write('\n\n');
    for (var s = 0; s < sentencesPerParagraph; s++) {
      final sentence = 'Paragraph $p sentence $s has a few words.';
      if (s > 0) text.write(' ');
      text.write(sentence);
      parts.add(sentence);
    }
  }
  return ReadAloudPlan.build(fullText: text.toString(), parts: parts);
}

ReadAloudSnapshot _snapshot(
  ReadAloudPlan plan, {
  required int segment,
  int word = 0,
  Set<int> failed = const {},
}) => ReadAloudSnapshot(
  plan: plan,
  status: ReadAloudStatus.playing,
  buffering: false,
  retrying: false,
  stalled: false,
  segment: segment,
  word: word,
  position: Duration.zero,
  duration: const Duration(minutes: 10),
  durationExact: false,
  failed: failed,
);

void main() {
  testWidgets('progress ticks rebuild only the paragraph being read', (
    tester,
  ) async {
    final plan = _plan(40, 5);
    late GatewayTextToSpeechService service;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            service = ref.watch(_serviceProvider);
            return MaterialApp(
              theme: AppTheme.light(TweakcnThemes.t3Chat),
              home: ReadAloudPanel(service: service, onCollapse: () {}),
            );
          },
        ),
      ),
    );

    List<RichText> paragraphs() => tester
        .widgetList<RichText>(find.byType(RichText))
        .where((rich) => rich.key is GlobalKey)
        .toList();

    service.readAloud.value = _snapshot(plan, segment: 0);
    await tester.pump();
    final before = paragraphs();
    expect(before, hasLength(40));

    service.readAloud.value = _snapshot(plan, segment: 1, word: 2);
    await tester.pump();
    var after = paragraphs();
    final changed = [
      for (var i = 0; i < before.length; i++)
        if (!identical(before[i], after[i])) i,
    ];
    expect(changed, hasLength(1));

    service.readAloud.value = _snapshot(plan, segment: 5, failed: {12});
    await tester.pump();
    final moved = paragraphs();
    final movedChanged = [
      for (var i = 0; i < after.length; i++)
        if (!identical(after[i], moved[i])) i,
    ];
    expect(movedChanged, hasLength(3));
    after = moved;

    final current = (after[1].text as TextSpan).children!.cast<TextSpan>();
    expect(
      current.where((span) => span.style?.backgroundColor != null),
      isNotEmpty,
    );
    final failed = (after[2].text as TextSpan).children!.cast<TextSpan>();
    expect(
      failed.where(
        (span) => span.style?.decoration == TextDecoration.underline,
      ),
      isNotEmpty,
    );

    service.readAloud.value = null;
    await tester.pump();
  });
}
