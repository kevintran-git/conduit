import 'dart:convert';

import 'package:conduit/inference_gateway/completions/reasoning_tag_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Golden / characterization test for the gateway's inline-reasoning rewrite.
///
/// `splitReasoningTagsInSseStream` is the function the gateway applies to raw
/// OpenAI SSE so inline `<think>…</think>` tags are folded into
/// `delta.reasoning_content` (rendered as the collapsible thinking widget)
/// instead of leaking into visible assistant content. This test pins the
/// byte-level rewrite so the inference_kit migration is provably identical
/// before and after.
Stream<List<int>> _bytes(List<String> frames) async* {
  for (final f in frames) {
    yield utf8.encode(f);
  }
}

String _frame(Map<String, dynamic> delta) =>
    'data: ${jsonEncode({
          'choices': [
            {'delta': delta},
          ],
        })}\n\n';

/// Decode the rewritten SSE byte stream back into the concatenated
/// `reasoning_content` and `content` the downstream parser would see.
Future<({String reasoning, String content})> _collect(
  Stream<List<int>> rewritten,
) async {
  final raw = utf8.decode(await rewritten.expand((c) => c).toList());
  final reasoning = StringBuffer();
  final content = StringBuffer();
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('data:')) continue;
    final payload = t.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') continue;
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final delta =
        ((json['choices'] as List).first as Map)['delta'] as Map? ?? {};
    if (delta['reasoning_content'] is String) {
      reasoning.write(delta['reasoning_content']);
    }
    if (delta['content'] is String) content.write(delta['content']);
  }
  return (reasoning: reasoning.toString(), content: content.toString());
}

void main() {
  group('splitReasoningTagsInSseStream (gateway reasoning rewrite)', () {
    test('folds a complete inline <think> block into reasoning_content',
        () async {
      final r = await _collect(
        splitReasoningTagsInSseStream(
          _bytes([
            _frame({'content': '<think>weighing options</think>Final answer'}),
            'data: [DONE]\n\n',
          ]),
        ),
      );
      expect(r.reasoning, contains('weighing options'));
      expect(r.content.trim(), 'Final answer');
      expect(r.content, isNot(contains('think')));
    });

    test('handles a tag straddling a chunk boundary', () async {
      final r = await _collect(
        splitReasoningTagsInSseStream(
          _bytes([
            _frame({'content': '<thi'}),
            _frame({'content': 'nk>secret</think>shown'}),
            'data: [DONE]\n\n',
          ]),
        ),
      );
      expect(r.reasoning, contains('secret'));
      expect(r.content, contains('shown'));
      expect(r.content, isNot(contains('<think>')));
    });

    test('passes through pre-split reasoning_content untouched', () async {
      final r = await _collect(
        splitReasoningTagsInSseStream(
          _bytes([
            _frame({'reasoning_content': 'native thoughts'}),
            _frame({'content': 'visible'}),
            'data: [DONE]\n\n',
          ]),
        ),
      );
      expect(r.reasoning, contains('native thoughts'));
      expect(r.content, contains('visible'));
    });

    test('leaves plain content with no tags unchanged', () async {
      final r = await _collect(
        splitReasoningTagsInSseStream(
          _bytes([
            _frame({'content': 'just a normal answer'}),
            'data: [DONE]\n\n',
          ]),
        ),
      );
      expect(r.reasoning, isEmpty);
      expect(r.content, 'just a normal answer');
    });
  });
}
