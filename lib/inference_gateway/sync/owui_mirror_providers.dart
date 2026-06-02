import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'owui_mirror_service.dart';

final owuiMirrorServiceProvider = Provider<OwuiMirrorService>((ref) {
  final service = OwuiMirrorService(ref);
  service.wire();
  ref.onDispose(service.dispose);
  return service;
});

/// Snapshot of how much work the mirror has queued for OWUI. Watched by the
/// connectivity overlay so it can show sync progress even while online (the
/// common case for a failed gateway push).
class OwuiMirrorStatus {
  const OwuiMirrorStatus({this.pending = 0, this.failed = 0});

  /// Conversations queued for OWUI (includes [failed]).
  final int pending;

  /// Conversations that have exhausted automatic retries and need attention.
  final int failed;

  bool get hasWork => pending > 0;

  OwuiMirrorStatus copyWith({int? pending, int? failed}) => OwuiMirrorStatus(
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );

  @override
  bool operator ==(Object other) =>
      other is OwuiMirrorStatus &&
      other.pending == pending &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(pending, failed);
}

/// Reactive mirror status. The [OwuiMirrorService] pushes updates here after
/// every enqueue / flush / failure; the UI watches it.
class OwuiMirrorStatusNotifier extends Notifier<OwuiMirrorStatus> {
  @override
  OwuiMirrorStatus build() => const OwuiMirrorStatus();

  void set({required int pending, required int failed}) {
    final next = OwuiMirrorStatus(pending: pending, failed: failed);
    if (next != state) state = next;
  }
}

final owuiMirrorStatusProvider =
    NotifierProvider<OwuiMirrorStatusNotifier, OwuiMirrorStatus>(
  OwuiMirrorStatusNotifier.new,
);
