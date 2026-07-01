import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/realtime_call_session.dart';
import '../domain/realtime_call_step.dart';

class GatewayRealtimeCallOverlay extends ConsumerWidget {
  const GatewayRealtimeCallOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(realtimeCallSessionProvider);
    final session = ref.read(realtimeCallSessionProvider.notifier);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: theme.brightness == Brightness.dark ? 0.45 : 0.18,
                  ),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                ),
              ],
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Header(
                  state: state,
                  onEndTap: () async {
                    HapticFeedback.mediumImpact();
                    await session.end();
                    onClose();
                  },
                ),
                _Transcript(state: state),
                const SizedBox(height: 22),
                _MuteButton(state: state, onTap: session.togglePause),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallStyle {
  const _CallStyle({
    required this.chipLabel,
    required this.chipIcon,
    required this.chipFill,
    required this.chipOnFill,
  });

  final String chipLabel;
  final IconData chipIcon;
  final Color chipFill;
  final Color chipOnFill;
}

_CallStyle _styleFor(RealtimeCallSessionState s, ColorScheme cs) {
  if (s.step == RealtimeCallStep.live && s.runningTool != null) {
    return _CallStyle(
      chipLabel: 'Using ${s.runningTool}',
      chipIcon: CupertinoIcons.gear_alt_fill,
      chipFill: cs.tertiary,
      chipOnFill: cs.onTertiary,
    );
  }
  if (s.muted) {
    return _CallStyle(
      chipLabel: 'Muted',
      chipIcon: CupertinoIcons.mic_slash_fill,
      chipFill: cs.surfaceContainerHighest,
      chipOnFill: cs.onSurfaceVariant,
    );
  }
  switch (s.step) {
    case RealtimeCallStep.idle:
      return _CallStyle(
        chipLabel: 'Connecting',
        chipIcon: CupertinoIcons.dot_radiowaves_left_right,
        chipFill: cs.surfaceContainerHighest,
        chipOnFill: cs.onSurfaceVariant,
      );
    case RealtimeCallStep.live:
      if (s.speaking) {
        return _CallStyle(
          chipLabel: 'Speaking',
          chipIcon: CupertinoIcons.speaker_3_fill,
          chipFill: cs.primary,
          chipOnFill: cs.onPrimary,
        );
      }
      return _CallStyle(
        chipLabel: 'Listening',
        chipIcon: CupertinoIcons.waveform,
        chipFill: cs.error,
        chipOnFill: cs.onError,
      );
    case RealtimeCallStep.error:
      return _CallStyle(
        chipLabel: s.errorMessage ?? 'Error',
        chipIcon: CupertinoIcons.exclamationmark_triangle_fill,
        chipFill: cs.error,
        chipOnFill: cs.onError,
      );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onEndTap});

  final RealtimeCallSessionState state;
  final VoidCallback onEndTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: _StatusChip(state: state)),
        const SizedBox(width: 12),
        _EndButton(onTap: onEndTap),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});
  final RealtimeCallSessionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = _styleFor(state, theme.colorScheme);
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: style.chipFill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(style.chipIcon, color: style.chipOnFill, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                style.chipLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: style.chipOnFill,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'End call',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(shape: BoxShape.circle, color: cs.error),
          child: Icon(CupertinoIcons.xmark, color: cs.onError, size: 18),
        ),
      ),
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.state});
  final RealtimeCallSessionState state;

  bool get _visible => state.step == RealtimeCallStep.live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = state.speaking ? state.outputTranscript : state.inputTranscript;
    final hasText = text.isNotEmpty;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: _visible
          ? Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56, maxHeight: 96),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      hasText ? text : 'Say something…',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: hasText ? cs.onSurface : cs.onSurfaceVariant,
                        fontWeight: hasText ? FontWeight.w500 : FontWeight.w400,
                        fontStyle: hasText ? FontStyle.normal : FontStyle.italic,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.state, required this.onTap});
  final RealtimeCallSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final disabled = state.step == RealtimeCallStep.error;
    final muted = state.muted;
    final fill = muted ? cs.outline : cs.primary;
    final onFill = cs.onPrimary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: muted ? 'Unmute mic' : 'Mute mic',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: disabled ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: disabled ? fill.withValues(alpha: 0.5) : fill,
                boxShadow: [
                  BoxShadow(
                    color: fill.withValues(alpha: 0.4),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: Icon(
                muted ? CupertinoIcons.mic_slash_fill : CupertinoIcons.mic_fill,
                size: 48,
                color: onFill,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          muted ? 'UNMUTE' : 'MUTE',
          style: theme.textTheme.labelMedium?.copyWith(
            color: cs.onSurface,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}
