import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../../core/persistence/hive_boxes.dart';

/// One dirty-conversation record waiting to be pushed to OWUI.
class OwuiMirrorEntry {
  OwuiMirrorEntry({
    required this.conversationId,
    required this.dirtyAt,
    this.retries = 0,
    this.lastError,
  });

  final String conversationId;
  DateTime dirtyAt;
  int retries;
  String? lastError;

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'dirtyAt': dirtyAt.toIso8601String(),
    'retries': retries,
    if (lastError != null) 'lastError': lastError,
  };

  factory OwuiMirrorEntry.fromJson(Map<String, dynamic> json) {
    return OwuiMirrorEntry(
      conversationId: json['conversationId'] as String,
      dirtyAt:
          DateTime.tryParse(json['dirtyAt']?.toString() ?? '') ?? DateTime.now(),
      retries: (json['retries'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
    );
  }
}

/// Persistent "needs-sync-to-OWUI" set, keyed by conversation ID.
///
/// Lives in the existing Hive `caches` box under the `owui_mirror::` prefix —
/// no schema migration. Each conversation appears at most once; we don't
/// queue per-turn events because we always push the full authoritative
/// snapshot from local state when we flush.
class OwuiMirrorOutbox {
  OwuiMirrorOutbox();

  static const String _prefix = 'owui_mirror::';

  /// After this many consecutive failures, drop the entry. A conversation
  /// that 4xxs forever (deleted server-side, perm change) shouldn't trap
  /// the flush loop in a permanent retry storm.
  static const int maxRetries = 8;

  Box<dynamic>? _box() {
    if (!Hive.isBoxOpen(HiveBoxNames.caches)) return null;
    return Hive.box<dynamic>(HiveBoxNames.caches);
  }

  String _keyFor(String conversationId) => '$_prefix$conversationId';

  Future<void> markDirty(String conversationId) async {
    final box = _box();
    if (box == null) return;
    final key = _keyFor(conversationId);
    final existing = _decode(box.get(key));
    final entry = existing != null
        ? (existing
          ..dirtyAt = DateTime.now()
          ..lastError = null)
        : OwuiMirrorEntry(
            conversationId: conversationId,
            dirtyAt: DateTime.now(),
          );
    await box.put(key, jsonEncode(entry.toJson()));
  }

  Future<void> markFlushed(String conversationId) async {
    final box = _box();
    if (box == null) return;
    await box.delete(_keyFor(conversationId));
  }

  /// True when [conversationId] has a pending push waiting to land on OWUI.
  /// Used by chat-merge logic to decide whether the server snapshot is
  /// authoritative (no pending push → trust server, including deletions)
  /// or stale relative to local (pending push → keep local).
  bool hasPending(String conversationId) {
    final box = _box();
    if (box == null) return false;
    return box.containsKey(_keyFor(conversationId));
  }

  /// Bump retries and persist the error. Returns true if the entry has
  /// exceeded [maxRetries] and was dropped — the caller should stop
  /// scheduling further flush attempts for it.
  Future<bool> recordFailure(String conversationId, Object error) async {
    final box = _box();
    if (box == null) return false;
    final key = _keyFor(conversationId);
    final entry = _decode(box.get(key));
    if (entry == null) return false;
    entry.retries += 1;
    entry.lastError = error.toString();
    if (entry.retries >= maxRetries) {
      await box.delete(key);
      return true;
    }
    await box.put(key, jsonEncode(entry.toJson()));
    return false;
  }

  List<OwuiMirrorEntry> pending() {
    final box = _box();
    if (box == null) return const [];
    final entries = <OwuiMirrorEntry>[];
    for (final key in box.keys) {
      if (key is! String || !key.startsWith(_prefix)) continue;
      final entry = _decode(box.get(key));
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  OwuiMirrorEntry? _decode(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return OwuiMirrorEntry.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
