import 'dart:io';

Future<void> main() async {
  final unmerged = await _unmergedPaths();
  if (unmerged.isEmpty) {
    print('No unmerged paths.');
    return;
  }

  final stillUnresolved = <String>[];
  for (final path in unmerged) {
    final resolved = await _isSubmodule(path)
        ? await _resolveSubmoduleConflict(path)
        : await _resolveTextConflicts(path);
    if (resolved) {
      print('auto-resolved: $path');
    } else {
      stillUnresolved.add(path);
    }
  }

  if (stillUnresolved.isEmpty) {
    print('All conflicts auto-resolved.');
    return;
  }
  print('Needs a human:');
  for (final path in stillUnresolved) {
    print('  $path');
  }
  exitCode = 1;
}

Future<List<String>> _unmergedPaths() async {
  final result = await Process.run('git', [
    'diff',
    '--name-only',
    '--diff-filter=U',
  ]);
  return (result.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

Future<bool> _isSubmodule(String path) async {
  final result = await Process.run('git', ['ls-files', '-u', '--', path]);
  return (result.stdout as String).contains('160000');
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

bool _isPureCommentDeletion(List<String> base, List<String> patch) {
  var i = 0, j = 0;
  while (i < base.length && j < patch.length) {
    if (base[i] == patch[j]) {
      i++;
      j++;
    } else if (_isStrippableCommentLine(base[i])) {
      i++;
    } else {
      return false;
    }
  }
  if (j != patch.length) return false;
  return base.skip(i).every(_isStrippableCommentLine);
}

Future<bool> _resolveTextConflicts(String path) async {
  final file = File(path);
  final lines = await file.readAsLines();
  final out = <String>[];
  var unresolvedCount = 0;
  var i = 0;

  while (i < lines.length) {
    if (!lines[i].startsWith('<<<<<<< ')) {
      out.add(lines[i]);
      i++;
      continue;
    }

    final blockStart = i;
    i++;
    final head = <String>[];
    while (i < lines.length &&
        !lines[i].startsWith('|||||||') &&
        !lines[i].startsWith('=======')) {
      head.add(lines[i++]);
    }

    List<String>? base;
    if (i < lines.length && lines[i].startsWith('|||||||')) {
      i++;
      base = <String>[];
      while (i < lines.length && !lines[i].startsWith('=======')) {
        base.add(lines[i++]);
      }
    }

    if (i >= lines.length || !lines[i].startsWith('=======')) {
      return false;
    }
    i++;
    final patch = <String>[];
    while (i < lines.length && !lines[i].startsWith('>>>>>>> ')) {
      patch.add(lines[i++]);
    }
    if (i >= lines.length) return false;
    i++;

    if (base != null && _isPureCommentDeletion(base, patch)) {
      out.addAll(head);
    } else {
      out.addAll(lines.sublist(blockStart, i));
      unresolvedCount++;
    }
  }

  if (unresolvedCount > 0) return false;

  await file.writeAsString('${out.join('\n')}\n');
  final add = await Process.run('git', ['add', '--', path]);
  return add.exitCode == 0;
}

Future<bool> _resolveSubmoduleConflict(String path) async {
  final result = await Process.run('git', ['ls-files', '-u', '--', path]);
  String? oursSha, theirsSha;
  for (final line in (result.stdout as String).split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 3) continue;
    final sha = parts[1];
    switch (parts[2].split('\t').first) {
      case '2':
        oursSha = sha;
      case '3':
        theirsSha = sha;
    }
  }
  if (oursSha == null || theirsSha == null) return false;
  if (oursSha == theirsSha) return _takeSubmodulePointer(path, oursSha);

  await _ensureCommit(path, oursSha);
  await _ensureCommit(path, theirsSha);

  final oursIsAncestor = await _isAncestor(path, oursSha, theirsSha);
  final theirsIsAncestor = await _isAncestor(path, theirsSha, oursSha);
  if (oursIsAncestor == theirsIsAncestor) {
    return false;
  }
  return _takeSubmodulePointer(path, oursIsAncestor ? theirsSha : oursSha);
}

Future<void> _ensureCommit(String path, String sha) async {
  final check = await Process.run('git', ['-C', path, 'cat-file', '-e', sha]);
  if (check.exitCode != 0) {
    await Process.run('git', ['-C', path, 'fetch', '--quiet', '--all']);
  }
}

Future<bool> _isAncestor(
  String path,
  String maybeAncestor,
  String descendant,
) async {
  final result = await Process.run('git', [
    '-C',
    path,
    'merge-base',
    '--is-ancestor',
    maybeAncestor,
    descendant,
  ]);
  return result.exitCode == 0;
}

Future<bool> _takeSubmodulePointer(String path, String sha) async {
  final update = await Process.run('git', [
    'update-index',
    '--cacheinfo',
    '160000,$sha,$path',
  ]);
  if (update.exitCode != 0) return false;
  await Process.run('git', ['-C', path, 'checkout', '--quiet', sha]);
  return true;
}
