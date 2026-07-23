import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/call_engine.dart';
import '../application/call_tts.dart';
import '../domain/call_step.dart';

class GatewayCallOverlay extends StatelessWidget {
  const GatewayCallOverlay({
    super.key,
    required this.state,
    required this.engine,
    required this.onClose,
  });

  final CallSessionState state;
  final CallEngine engine;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomInset = MediaQuery.paddingOf(context).bottom + 8;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottomInset),
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.activeToolNames.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _ActiveToolsBanner(
                  key: ValueKey(state.activeToolNames),
                  toolNames: state.activeToolNames,
                ),
              ),
            Container(
              constraints: const BoxConstraints(maxWidth: 480),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: theme.brightness == Brightness.dark ? 0.45 : 0.18,
                    ),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _ModeIconButton(
                    manual: state.manualEosOnly,
                    onToggle: engine.setManualEosOnly,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _StatusLine(state: state)),
                  const SizedBox(width: 8),
                  _MuteButton(state: state, onTap: engine.toggleMute),
                  const SizedBox(width: 8),
                  _MicButton(state: state, onTap: engine.tapMicButton),
                  const SizedBox(width: 8),
                  _EndButton(
                    onTap: () async {
                      HapticFeedback.mediumImpact();
                      await engine.end();
                      onClose();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveToolsBanner extends StatefulWidget {
  const _ActiveToolsBanner({super.key, required this.toolNames});

  final List<String> toolNames;

  @override
  State<_ActiveToolsBanner> createState() => _ActiveToolsBannerState();
}

class _ActiveToolsBannerState extends State<_ActiveToolsBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: const ValueKey('gateway-active-tools-banner'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => setState(() => _dismissed = true),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.checkmark_seal,
              size: 14,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Tools: ${widget.toolNames.join(', ')}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
    required this.micLabel,
    required this.micIcon,
    required this.micFill,
    required this.micOnFill,
  });

  final String chipLabel;
  final IconData chipIcon;
  final Color chipFill;
  final Color chipOnFill;

  final String micLabel;
  final IconData micIcon;
  final Color micFill;
  final Color micOnFill;
}

const IconData _kInterruptIcon = CupertinoIcons.stop_fill;
const String _kInterruptLabel = 'Interrupt';

_CallStyle _styleFor(CallSessionState s, ColorScheme cs) {
  if (s.reconnecting) {
    return _CallStyle(
      chipLabel: 'Reconnecting',
      chipIcon: CupertinoIcons.arrow_2_circlepath,
      chipFill: cs.surfaceContainerHighest,
      chipOnFill: cs.onSurfaceVariant,
      micLabel: 'Reconnecting',
      micIcon: CupertinoIcons.hourglass,
      micFill: cs.outline,
      micOnFill: cs.onPrimary,
    );
  }
  if (s.runningTool != null) {
    return _CallStyle(
      chipLabel: 'Using ${s.runningTool}',
      chipIcon: CupertinoIcons.gear_alt_fill,
      chipFill: cs.tertiary,
      chipOnFill: cs.onTertiary,
      micLabel: _kInterruptLabel,
      micIcon: _kInterruptIcon,
      micFill: cs.primary,
      micOnFill: cs.onPrimary,
    );
  }
  switch (s.step) {
    case CallStep.idle:
      if (s.muted) {
        return _CallStyle(
          chipLabel: 'Muted',
          chipIcon: CupertinoIcons.mic_slash_fill,
          chipFill: cs.surfaceContainerHighest,
          chipOnFill: cs.onSurfaceVariant,
          micLabel: 'Muted',
          micIcon: CupertinoIcons.mic_slash_fill,
          micFill: cs.outline,
          micOnFill: cs.onPrimary,
        );
      }
      return _CallStyle(
        chipLabel: 'Connecting',
        chipIcon: CupertinoIcons.dot_radiowaves_left_right,
        chipFill: cs.surfaceContainerHighest,
        chipOnFill: cs.onSurfaceVariant,
        micLabel: 'Connecting',
        micIcon: CupertinoIcons.hourglass,
        micFill: cs.outline,
        micOnFill: cs.onPrimary,
      );
    case CallStep.listening:
      if (s.committing) {
        return _CallStyle(
          chipLabel: 'Sending',
          chipIcon: CupertinoIcons.arrow_up_circle_fill,
          chipFill: cs.tertiary,
          chipOnFill: cs.onTertiary,
          micLabel: 'Sending',
          micIcon: CupertinoIcons.hourglass,
          micFill: cs.tertiary,
          micOnFill: cs.onTertiary,
        );
      }
      if (s.isLive && !s.manualEosOnly) {
        return _CallStyle(
          chipLabel: 'Listening',
          chipIcon: CupertinoIcons.waveform,
          chipFill: cs.error,
          chipOnFill: cs.onError,
          micLabel: 'Listening',
          micIcon: CupertinoIcons.mic_fill,
          micFill: cs.error,
          micOnFill: cs.onError,
        );
      }
      return _CallStyle(
        chipLabel: 'Listening',
        chipIcon: CupertinoIcons.waveform,
        chipFill: cs.error,
        chipOnFill: cs.onError,
        micLabel: 'Send',
        micIcon: CupertinoIcons.arrow_up_circle_fill,
        micFill: cs.error,
        micOnFill: cs.onError,
      );
    case CallStep.thinking:
      switch (s.tts.stage) {
        case TtsStage.connecting:
        case TtsStage.idle:
        case TtsStage.playing:
        case TtsStage.drained:
        case TtsStage.stopped:
          return _CallStyle(
            chipLabel: 'Thinking',
            chipIcon: CupertinoIcons.sparkles,
            chipFill: cs.tertiary,
            chipOnFill: cs.onTertiary,
            micLabel: _kInterruptLabel,
            micIcon: _kInterruptIcon,
            micFill: cs.primary,
            micOnFill: cs.onPrimary,
          );
        case TtsStage.waiting:
          return _CallStyle(
            chipLabel: 'Streaming reply',
            chipIcon: CupertinoIcons.arrow_right_circle_fill,
            chipFill: cs.tertiary,
            chipOnFill: cs.onTertiary,
            micLabel: _kInterruptLabel,
            micIcon: _kInterruptIcon,
            micFill: cs.primary,
            micOnFill: cs.onPrimary,
          );
        case TtsStage.error:
          return _CallStyle(
            chipLabel: 'Voice error — tap mic to retry',
            chipIcon: CupertinoIcons.exclamationmark_triangle_fill,
            chipFill: cs.error,
            chipOnFill: cs.onError,
            micLabel: _kInterruptLabel,
            micIcon: _kInterruptIcon,
            micFill: cs.primary,
            micOnFill: cs.onPrimary,
          );
      }
    case CallStep.speaking:
      return _CallStyle(
        chipLabel: 'Speaking',
        chipIcon: CupertinoIcons.speaker_3_fill,
        chipFill: cs.primary,
        chipOnFill: cs.onPrimary,
        micLabel: _kInterruptLabel,
        micIcon: _kInterruptIcon,
        micFill: cs.primary,
        micOnFill: cs.onPrimary,
      );
    case CallStep.error:
      return _CallStyle(
        chipLabel: s.errorMessage ?? 'Error',
        chipIcon: CupertinoIcons.exclamationmark_triangle_fill,
        chipFill: cs.error,
        chipOnFill: cs.onError,
        micLabel: 'Error',
        micIcon: CupertinoIcons.exclamationmark,
        micFill: cs.error,
        micOnFill: cs.onError,
      );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});
  final CallSessionState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final showTranscript =
        !state.isLive &&
        state.sttReady &&
        state.step == CallStep.listening &&
        state.partialTranscript.trim().isNotEmpty;

    if (showTranscript) {
      return Text(
        state.partialTranscript.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: cs.onSurface,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final style = _styleFor(state, cs);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(style.chipIcon, size: 16, color: style.chipFill),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            style.chipLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.fill,
    required this.onFill,
    required this.semanticLabel,
    this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final Color fill;
  final Color onFill;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool highlighted;

  static const double _size = 44;
  static const double _iconSize = 20;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: disabled ? fill.withValues(alpha: 0.5) : fill,
            boxShadow: !disabled && highlighted
                ? [
                    BoxShadow(
                      color: fill.withValues(alpha: 0.4),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Icon(icon, size: _iconSize, color: onFill),
        ),
      ),
    );
  }
}

class _ModeIconButton extends StatelessWidget {
  const _ModeIconButton({required this.manual, required this.onToggle});
  final bool manual;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _CircleButton(
      icon: manual
          ? CupertinoIcons.hand_point_right_fill
          : CupertinoIcons.bolt_fill,
      fill: cs.surfaceContainerHighest,
      onFill: cs.onSurfaceVariant,
      semanticLabel: manual ? 'Switch to auto-send' : 'Switch to tap-to-send',
      onTap: () {
        HapticFeedback.selectionClick();
        onToggle(!manual);
      },
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.state, required this.onTap});
  final CallSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled =
        !state.muted &&
        (state.step == CallStep.idle || state.step == CallStep.error);
    final muted = state.muted;

    return _CircleButton(
      icon: muted ? CupertinoIcons.mic_slash_fill : CupertinoIcons.mic_fill,
      fill: muted ? cs.primary : cs.surfaceContainerHighest,
      onFill: muted ? cs.onPrimary : cs.onSurfaceVariant,
      semanticLabel: muted ? 'Unmute mic' : 'Mute mic',
      onTap: disabled ? null : onTap,
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.state, required this.onTap});
  final CallSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = _styleFor(state, cs);
    final disabled =
        state.reconnecting ||
        state.step == CallStep.idle ||
        state.step == CallStep.error ||
        (state.step == CallStep.listening && state.committing) ||
        (state.step == CallStep.listening &&
            state.isLive &&
            !state.manualEosOnly);

    return _CircleButton(
      icon: style.micIcon,
      fill: style.micFill,
      onFill: style.micOnFill,
      semanticLabel: style.micLabel,
      onTap: disabled ? null : onTap,
      highlighted: state.step == CallStep.listening,
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _CircleButton(
      icon: CupertinoIcons.xmark,
      fill: cs.error,
      onFill: cs.onError,
      semanticLabel: 'End call',
      onTap: onTap,
    );
  }
}
