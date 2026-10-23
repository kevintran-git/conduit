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

Future<GatewayTextToSpeechService> _pumpPanel(WidgetTester tester) async {
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
  return service;
}

Map<Key, RichText> _paragraphs(WidgetTester tester) => {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
    if (rich.key is GlobalKey) rich.key!: rich,
};

List<Key> _changed(Map<Key, RichText> before, Map<Key, RichText> after) => [
  for (final entry in after.entries)
    if (before[entry.key] != null && !identical(before[entry.key], entry.value))
      entry.key,
];

void main() {
  testWidgets('progress ticks rebuild only the paragraph being read', (
    tester,
  ) async {
    final plan = _plan(40, 5);
    final service = await _pumpPanel(tester);

    service.readAloud.value = _snapshot(plan, segment: 0);
    await tester.pump();
    final before = _paragraphs(tester);
    expect(before.length, lessThan(40));

    service.readAloud.value = _snapshot(plan, segment: 1, word: 2);
    await tester.pump();
    final after = _paragraphs(tester);
    expect(_changed(before, after), hasLength(1));

    service.readAloud.value = _snapshot(plan, segment: 5, failed: {12});
    await tester.pump();
    final moved = _paragraphs(tester);
    expect(_changed(after, moved), hasLength(3));

    final ordered = moved.values.toList();
    final current = (ordered[1].text as TextSpan).children!.cast<TextSpan>();
    expect(
      current.where((span) => span.style?.backgroundColor != null),
      isNotEmpty,
    );
    final failed = (ordered[2].text as TextSpan).children!.cast<TextSpan>();
    expect(
      failed.where(
        (span) => span.style?.decoration == TextDecoration.underline,
      ),
      isNotEmpty,
    );

    service.readAloud.value = null;
    await tester.pump();
  });

  testWidgets('a long note builds only nearby paragraphs and follows far', (
    tester,
  ) async {
    final plan = _plan(2000, 5);
    final service = await _pumpPanel(tester);

    service.readAloud.value = _snapshot(plan, segment: 0);
    await tester.pump();
    expect(_paragraphs(tester).length, lessThan(40));

    service.readAloud.value = _snapshot(plan, segment: 1500 * 5);
    await tester.pumpAndSettle();
    final built = _paragraphs(tester);
    expect(built.length, lessThan(40));
    final highlighted = built.values.where(
      (rich) => (rich.text as TextSpan).children!.cast<TextSpan>().any(
        (span) => span.style?.backgroundColor != null,
      ),
    );
    expect(highlighted, hasLength(1));
    final box = tester.renderObject<RenderBox>(
      find.byWidget(highlighted.single),
    );
    final top = box.localToGlobal(Offset.zero).dy;
    expect(top, greaterThanOrEqualTo(0));
    expect(top, lessThan(600));

    service.readAloud.value = null;
    await tester.pump();
  });
}
