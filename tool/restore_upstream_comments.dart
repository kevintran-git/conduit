import 'dart:io';

Future<void> main(List<String> args) async {
  final upstreamRef = args.isNotEmpty ? args[0] : 'upstream/main';
  final files = await _upstreamOwnedTouchedFiles(upstreamRef);

  final restored = <String>[];
  for (final file in files) {
    if (await _restoreFile(file, upstreamRef)) restored.add(file);
  }

  for (final file in restored) {
    print(file);
  }
}

Future<List<String>> _upstreamOwnedTouchedFiles(String upstreamRef) async {
  final diff = await Process.run('git', [
    'diff',
    '--name-only',
    upstreamRef,
    'HEAD',
  ]);
  final candidates = (diff.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);

  final owned = <String>[];
  for (final file in candidates) {
    final exists = await Process.run('git', [
      'cat-file',
      '-e',
      '$upstreamRef:$file',
    ]);
    if (exists.exitCode == 0) owned.add(file);
  }
  return owned;
}

bool _isStrippableCommentLine(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('//')) return false;
  if (trimmed.startsWith('///')) return false;
  if (RegExp(r'^//\s*(ignore|eslint-disable)').hasMatch(trimmed)) {
    return false;
  }
  return true;
}

/// A trailing `  // comment` stripped from the end of an otherwise-unchanged
/// line looks like a full-line replacement in a unified diff. Detect that
/// shape so it's restored like any other dropped comment.
String? _strippableTrailingComment(String withComment, String withoutComment) {
  if (!withComment.startsWith(withoutComment.trimRight())) return null;
  final suffix = withComment.substring(withoutComment.trimRight().length);
  final commentStart = suffix.indexOf('//');
  if (commentStart == -1) return null;
  if (suffix.substring(0, commentStart).trim().isNotEmpty) return null;
  return _isStrippableCommentLine(suffix.substring(commentStart))
      ? suffix.substring(commentStart)
      : null;
}

class _Hunk {
  _Hunk(this.newStart, this.newCount, this.removed, this.added);

  final int newStart;
  final int newCount;
  final List<String> removed;
  final List<String> added;
}

List<_Hunk> _parseHunks(String unifiedDiff) {
  final hunks = <_Hunk>[];
  final headerRe = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
  final lines = unifiedDiff.split('\n');
  var i = 0;
  while (i < lines.length && !lines[i].startsWith('@@ ')) {
    i++;
  }
  while (i < lines.length) {
    final match = headerRe.firstMatch(lines[i]);
    if (match == null) break;
    final newStart = int.parse(match.group(3)!);
    final newCount = match.group(4) == null ? 1 : int.parse(match.group(4)!);
    i++;
    final removed = <String>[];
    final added = <String>[];
    while (i < lines.length && !lines[i].startsWith('@@ ')) {
      final line = lines[i];
      if (line.startsWith('-')) {
        removed.add(line.substring(1));
      } else if (line.startsWith('+')) {
        added.add(line.substring(1));
      }
      i++;
    }
    hunks.add(_Hunk(newStart, newCount, removed, added));
  }
  return hunks;
}

/// Whether this hunk only drops comment text relative to upstream — either a
/// standalone comment line, or a comment trimmed off the end of a line that's
/// otherwise unchanged. Returns the lines to reinstate, or null if the hunk
/// contains a real functional change that must be left alone.
List<String>? _restorableLines(_Hunk hunk) {
  if (hunk.added.isEmpty) {
    return hunk.removed.every(_isStrippableCommentLine) ? hunk.removed : null;
  }
  if (hunk.removed.length != hunk.added.length) return null;
  for (var i = 0; i < hunk.removed.length; i++) {
    if (hunk.removed[i] == hunk.added[i]) continue;
    if (_strippableTrailingComment(hunk.removed[i], hunk.added[i]) == null) {
      return null;
    }
  }
  return hunk.removed;
}

Future<bool> _restoreFile(String file, String upstreamRef) async {
  final diffResult = await Process.run('git', [
    'diff',
    '--no-color',
    '-U0',
    upstreamRef,
    'HEAD',
    '--',
    file,
  ]);
  final hunks = _parseHunks(diffResult.stdout as String);
  if (hunks.isEmpty) return false;

  final current = await File(file).readAsLines();
  var changed = false;

  for (final hunk in hunks.reversed) {
    final restore = _restorableLines(hunk);
    if (restore == null) continue;
    changed = true;
    if (hunk.newCount == 0) {
      current.insertAll(hunk.newStart, restore);
    } else {
      current.replaceRange(
        hunk.newStart - 1,
        hunk.newStart - 1 + hunk.newCount,
        restore,
      );
    }
  }

  if (!changed) return false;
  await File(file).writeAsString('${current.join('\n')}\n');
  final add = await Process.run('git', ['add', '--', file]);
  return add.exitCode == 0;
}
