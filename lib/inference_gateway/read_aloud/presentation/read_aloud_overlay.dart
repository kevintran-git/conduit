import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../chat_tts/gateway_text_to_speech_service.dart';
import '../read_aloud_engine.dart';
import 'read_aloud_panel.dart';

class ReadAloudOverlayHost {
  ReadAloudOverlayHost({required this.service}) {
    service.readAloud.addListener(_sync);
    service.readAloudNotice.addListener(_sync);
  }

  final GatewayTextToSpeechService service;
  final ValueNotifier<bool> _expanded = ValueNotifier(false);
  OverlayEntry? _entry;

  void _sync() {
    final active =
        service.readAloud.value != null ||
        service.readAloudNotice.value != null;
    if (active && _entry == null) {
      final overlay = NavigationService.navigatorKey.currentState?.overlay;
      if (overlay == null) return;
      final entry = _entry = OverlayEntry(
        builder: (_) => ReadAloudOverlay(service: service, expanded: _expanded),
      );
      overlay.insert(entry);
    } else if (!active && _entry != null) {
      _entry!.remove();
      _entry = null;
      _expanded.value = false;
    }
  }

  void dispose() {
    service.readAloud.removeListener(_sync);
    service.readAloudNotice.removeListener(_sync);
    _entry?.remove();
    _entry = null;
    _expanded.dispose();
  }
}

class ReadAloudOverlay extends StatelessWidget {
  const ReadAloudOverlay({
    super.key,
    required this.service,
    required this.expanded,
  });

  final GatewayTextToSpeechService service;
  final ValueNotifier<bool> expanded;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: expanded,
      builder: (context, isExpanded, _) {
        if (isExpanded) {
          return Positioned.fill(
            child: ReadAloudPanel(
              service: service,
              onCollapse: () => expanded.value = false,
            ),
          );
        }
        return Positioned(
          top: MediaQuery.paddingOf(context).top + kToolbarHeight + Spacing.sm,
          left: Spacing.md,
          right: Spacing.md,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<ReadAloudNotice?>(
                valueListenable: service.readAloudNotice,
                builder: (context, notice, _) => AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  child: notice == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: Spacing.sm),
                          child: _NoticeBar(
                            notice: notice,
                            onClose: service.dismissReadAloudNotice,
                          ),
                        ),
                ),
              ),
              ValueListenableBuilder<ReadAloudSnapshot?>(
                valueListenable: service.readAloud,
                builder: (context, snapshot, _) => snapshot == null
                    ? const SizedBox.shrink()
                    : _MiniBar(
                        snapshot: snapshot,
                        service: service,
                        onExpand: () => expanded.value = true,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({
    required this.snapshot,
    required this.service,
    required this.onExpand,
  });

  final ReadAloudSnapshot snapshot;
  final GatewayTextToSpeechService service;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final segment = snapshot.plan.segments[snapshot.segment];
    final sentence = snapshot.plan.parts[segment.partIndex].substring(
      segment.start,
      segment.end,
    );
    final total = snapshot.duration.inMilliseconds;
    final progress = total <= 0
        ? 0.0
        : (snapshot.position.inMilliseconds / total).clamp(0.0, 1.0);
    return Material(
      color: theme.cardBackground,
      elevation: 6,
      borderRadius: BorderRadius.circular(AppBorderRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onExpand,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              child: Row(
                children: [
                  ReadAloudPlayButton(snapshot: snapshot, service: service),
                  Expanded(
                    child: Text(
                      readAloudStatusLine(snapshot) ?? sentence,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: readAloudStatusLine(snapshot) == null
                            ? theme.textPrimary
                            : theme.textSecondary,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Expand',
                    icon: Icon(Icons.open_in_full, color: theme.iconSecondary),
                    onPressed: onExpand,
                  ),
                  IconButton(
                    tooltip: 'Stop',
                    icon: Icon(Icons.close, color: theme.iconSecondary),
                    onPressed: () => unawaited(service.stop()),
                  ),
                ],
              ),
            ),
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              color: theme.buttonPrimary,
              backgroundColor: theme.dividerColor,
            ),
          ],
        ),
      ),
    );
  }
}

String? readAloudStatusLine(ReadAloudSnapshot snapshot) {
  if (snapshot.stalled) return 'Connection lost. Tap play to retry.';
  if (snapshot.retrying) return 'Reconnecting…';
  if (snapshot.status == ReadAloudStatus.loading && !snapshot.isPaused) {
    return 'Preparing audio…';
  }
  return null;
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.notice, required this.onClose});

  final ReadAloudNotice notice;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Material(
      color: theme.cardBackground,
      elevation: 6,
      borderRadius: BorderRadius.circular(AppBorderRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.only(left: Spacing.md, right: Spacing.xs),
        child: Row(
          children: [
            Icon(
              notice.error ? Icons.error_outline : Icons.info_outline,
              color: notice.error ? theme.error : theme.iconSecondary,
              size: IconSize.lg,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                notice.message,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: theme.textPrimary),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: Icon(Icons.close, color: theme.iconSecondary),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class ReadAloudPlayButton extends StatelessWidget {
  const ReadAloudPlayButton({
    super.key,
    required this.snapshot,
    required this.service,
    this.size = IconSize.lg,
  });

  final ReadAloudSnapshot snapshot;
  final GatewayTextToSpeechService service;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final waiting =
        snapshot.status == ReadAloudStatus.loading || snapshot.buffering;
    final Widget icon = waiting
        ? SizedBox(
            width: size,
            height: size,
            child: Padding(
              padding: EdgeInsets.all(size / 6),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.loadingIndicator,
              ),
            ),
          )
        : Icon(
            snapshot.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: size,
            color: theme.iconPrimary,
          );
    return IconButton(
      tooltip: snapshot.isPaused ? 'Play' : 'Pause',
      icon: icon,
      onPressed: () => unawaited(service.togglePause()),
    );
  }
}
