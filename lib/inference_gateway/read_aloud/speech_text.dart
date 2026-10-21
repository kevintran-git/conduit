final _emoji = RegExp(
  '[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]',
  unicode: true,
);
final _repeatedMarks = RegExp(r'([!?,;:])\1+');
final _longEllipsis = RegExp(r'\.{4,}');
final _quoteBeforePunctuation = RegExp(
  '^(.*[\\p{L}\\p{N}])(["”’\'])([.,])\$',
  unicode: true,
);
final _wordCore = RegExp(
  r'^([^\p{L}\p{N}]*)(.*?)([^\p{L}\p{N}]*)$',
  unicode: true,
);
final _romanNumeral = RegExp(r'^[IVXLCDM]{1,8}$');
final _nonLetter = RegExp(r'[^\p{L}]', unicode: true);

const _divisionWords = {
  'chapter',
  'part',
  'book',
  'act',
  'volume',
  'section',
  'step',
  'phase',
};

const _letterLabels = {'C', 'D', 'L', 'M'};

const _unambiguousDivisionWords = {'chapter', 'volume'};

const _romanTable = [
  (1000, 'M'),
  (900, 'CM'),
  (500, 'D'),
  (400, 'CD'),
  (100, 'C'),
  (90, 'XC'),
  (50, 'L'),
  (40, 'XL'),
  (10, 'X'),
  (9, 'IX'),
  (5, 'V'),
  (4, 'IV'),
  (1, 'I'),
];

String _intToRoman(int value) {
  final out = StringBuffer();
  var rest = value;
  for (final (n, s) in _romanTable) {
    while (rest >= n) {
      out.write(s);
      rest -= n;
    }
  }
  return out.toString();
}

int? romanToInt(String roman) {
  if (!_romanNumeral.hasMatch(roman)) return null;
  int valueOf(String c) => _romanTable.firstWhere((e) => e.$2 == c).$1;
  var total = 0;
  for (var i = 0; i < roman.length; i++) {
    final value = valueOf(roman[i]);
    final next = i + 1 < roman.length ? valueOf(roman[i + 1]) : 0;
    total += next > value ? -value : value;
  }
  return _intToRoman(total) == roman ? total : null;
}

String spokenWord(
  String word, {
  String? previous,
  Map<String, String> pronunciations = const {},
}) {
  var out = word.replaceAll(_emoji, '');
  if (out.isEmpty) return '';
  out = out
      .replaceAllMapped(_repeatedMarks, (m) => m.group(1)!)
      .replaceAll(_longEllipsis, '...');
  final quote = _quoteBeforePunctuation.firstMatch(out);
  if (quote != null) {
    out = '${quote.group(1)}${quote.group(3)}${quote.group(2)}';
  }
  final parts = _wordCore.firstMatch(out)!;
  var core = parts.group(2)!;
  final division = previous?.replaceAll(_nonLetter, '').toLowerCase();
  if (division != null &&
      _divisionWords.contains(division) &&
      !_letterLabels.contains(core) &&
      (core != 'I' || _unambiguousDivisionWords.contains(division))) {
    final n = romanToInt(core);
    if (n != null) core = '$n';
  }
  core = pronunciations[core.toLowerCase()] ?? core;
  return '${parts.group(1)}$core${parts.group(3)}';
}

List<String> normalizeWords(
  List<String> words, {
  Map<String, String> pronunciations = const {},
}) {
  return [
    for (var i = 0; i < words.length; i++)
      spokenWord(
        words[i],
        previous: i > 0 ? words[i - 1] : null,
        pronunciations: pronunciations,
      ),
  ];
}

Map<String, String> parsePronunciations(String source) {
  final out = <String, String>{};
  for (final line in source.split('\n')) {
    final i = line.indexOf('=');
    if (i <= 0) continue;
    final key = line.substring(0, i).trim().toLowerCase();
    final value = line.substring(i + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty && !key.contains(' ')) {
      out[key] = value;
    }
  }
  return out;
}
