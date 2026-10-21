import 'dart:math' as math;

import 'speech_text.dart';

final _word = RegExp(r'\S+');
final _sentenceEnd = RegExp(r'[.!?…]["”’)\]]*$');
final _clauseEnd = RegExp(r'[,;:—]$');
final _trailingClosers = RegExp('["\'’”)\\]]+\$');

const int _maxSegmentWords = 60;
const int _splitSearchFrom = 25;

int pauseWeight(String word) {
  final trimmed = word.replaceAll(_trailingClosers, '');
  if (trimmed.isEmpty) return 0;
  return switch (trimmed[trimmed.length - 1]) {
    '.' || '!' || '?' || '…' => 6,
    ',' || ';' || ':' || '—' => 3,
    _ => 0,
  };
}

class PlanWord {
  const PlanWord({
    required this.start,
    required this.end,
    required this.weight,
  });

  final int start;
  final int end;
  final int weight;
}

class PlanSegment {
  const PlanSegment({
    required this.index,
    required this.partIndex,
    required this.start,
    required this.end,
    required this.words,
    required this.spokenText,
    required this.endsParagraph,
  });

  final int index;
  final int partIndex;
  final int start;
  final int end;
  final List<PlanWord> words;
  final String spokenText;
  final bool endsParagraph;

  bool get silent => spokenText.isEmpty;

  int get totalWeight => words.fold(0, (sum, w) => sum + w.weight);

  List<({int startMs, int endMs})> wordTimings(int durationMs) {
    final total = totalWeight;
    if (words.isEmpty || total <= 0) {
      return [for (final _ in words) (startMs: 0, endMs: durationMs)];
    }
    final out = <({int startMs, int endMs})>[];
    var acc = 0;
    for (final word in words) {
      final start = durationMs * acc ~/ total;
      acc += word.weight;
      out.add((startMs: start, endMs: durationMs * acc ~/ total));
    }
    return out;
  }

  int wordIndexAt(int positionMs, int durationMs) {
    if (words.isEmpty) return -1;
    final timings = wordTimings(durationMs);
    for (var i = 0; i < timings.length; i++) {
      if (positionMs < timings[i].endMs) return i;
    }
    return words.length - 1;
  }

  int msForWord(int wordIndex, int durationMs) {
    if (words.isEmpty) return 0;
    final i = wordIndex.clamp(0, words.length - 1);
    return wordTimings(durationMs)[i].startMs;
  }
}

class ReadAloudPlan {
  ReadAloudPlan._({
    required this.parts,
    required this.partOffsets,
    required this.paragraphStarts,
    required this.segments,
  });

  final List<String> parts;
  final List<int> partOffsets;
  final Set<int> paragraphStarts;
  final List<PlanSegment> segments;

  factory ReadAloudPlan.build({
    required String fullText,
    required List<String> parts,
    Map<String, String> pronunciations = const {},
  }) {
    final offsets = _partOffsets(fullText, parts);
    final paragraphStarts = <int>{};
    for (var i = 0; i < parts.length; i++) {
      if (i == 0) {
        paragraphStarts.add(0);
        continue;
      }
      final prevEnd = offsets[i - 1] + parts[i - 1].trim().length;
      final start = offsets[i];
      if (start > prevEnd && start <= fullText.length) {
        final between = fullText.substring(prevEnd, start);
        if (between.contains('\n')) paragraphStarts.add(i);
      }
    }

    final segments = <PlanSegment>[];
    for (var p = 0; p < parts.length; p++) {
      final part = parts[p];
      final matches = _word.allMatches(part).toList();
      final groups = _groupWords(matches);
      final endsParagraph =
          p == parts.length - 1 || paragraphStarts.contains(p + 1);
      for (var g = 0; g < groups.length; g++) {
        final group = groups[g];
        final texts = [for (final m in group) m.group(0)!];
        final spoken = normalizeWords(
          texts,
          pronunciations: pronunciations,
        ).where((w) => w.isNotEmpty).join(' ');
        final words = <PlanWord>[
          for (var i = 0; i < group.length; i++)
            PlanWord(
              start: group[i].start,
              end: group[i].end,
              weight: spokenWord(texts[i]).isEmpty
                  ? 0
                  : math.max(1, texts[i].length) + pauseWeight(texts[i]),
            ),
        ];
        segments.add(
          PlanSegment(
            index: segments.length,
            partIndex: p,
            start: group.first.start,
            end: group.last.end,
            words: words,
            spokenText: spoken,
            endsParagraph: endsParagraph && g == groups.length - 1,
          ),
        );
      }
    }

    return ReadAloudPlan._(
      parts: List.unmodifiable(parts),
      partOffsets: List.unmodifiable(offsets),
      paragraphStarts: paragraphStarts,
      segments: List.unmodifiable(segments),
    );
  }

  static List<int> _partOffsets(String source, List<String> parts) {
    final offsets = <int>[];
    var cursor = 0;
    for (final part in parts) {
      final chunk = part.trim();
      if (chunk.isEmpty) {
        offsets.add(cursor);
        continue;
      }
      final index = source.indexOf(chunk, cursor);
      if (index == -1) {
        offsets.add(cursor);
        cursor += chunk.length;
      } else {
        offsets.add(index);
        cursor = index + chunk.length;
      }
    }
    return offsets;
  }

  static List<List<RegExpMatch>> _groupWords(List<RegExpMatch> words) {
    final sentences = <List<RegExpMatch>>[];
    var current = <RegExpMatch>[];
    for (final word in words) {
      current.add(word);
      if (_sentenceEnd.hasMatch(word.group(0)!)) {
        sentences.add(current);
        current = <RegExpMatch>[];
      }
    }
    if (current.isNotEmpty) sentences.add(current);

    final out = <List<RegExpMatch>>[];
    for (final sentence in sentences) {
      var rest = sentence;
      while (rest.length > _maxSegmentWords) {
        var cut = -1;
        for (var i = _maxSegmentWords - 1; i >= _splitSearchFrom; i--) {
          if (_clauseEnd.hasMatch(rest[i].group(0)!)) {
            cut = i + 1;
            break;
          }
        }
        if (cut < 0) cut = _maxSegmentWords;
        out.add(rest.sublist(0, cut));
        rest = rest.sublist(cut);
      }
      if (rest.isNotEmpty) out.add(rest);
    }
    return out;
  }

  int get totalWeight => segments.fold(0, (sum, s) => sum + s.totalWeight);

  int segmentAtPartOffset(int partIndex, int offsetInPart) {
    var best = -1;
    for (final segment in segments) {
      if (segment.partIndex < partIndex) {
        best = segment.index;
        continue;
      }
      if (segment.partIndex > partIndex) break;
      if (segment.start <= offsetInPart || best < 0) best = segment.index;
    }
    return best < 0 ? 0 : best;
  }
}
