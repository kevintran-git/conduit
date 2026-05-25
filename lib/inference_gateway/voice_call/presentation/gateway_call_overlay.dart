import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../application/call_session.dart';
import '../application/call_tts.dart';
import '../domain/call_step.dart';

/// Bottom-anchored call surface. Layout reads top→bottom: status chip + End
/// in a slim header, the live transcript as the dominant visual surface, the
/// Auto/Tap mode toggle (gateway STT only), and an action row where the Mic
/// is the unmistakable primary action — Pause sits to its left, smaller and
/// clearly secondary, and End lives up in the corner so it can't be hit by
/// accident while reaching for Send/Interrupt.
class GatewayCallOverlay extends ConsumerWidget {
  const GatewayCallOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(callSessionProvider);
    final session = ref.read(callSessionProvider.notifier);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // The Auto/Tap toggle only meaningfully gates EOS for gateway STT — on
    // device STT (Apple/Android system recognizer) the OS has its own VAD
    // that fires `onEndOfSpeech` independent of our `pauseFor` hint, so
    // showing the toggle would lie to the user. Hide it instead.
    final sttPref = ref.watch(
      appSettingsProvider.select((s) => s.sttPreference),
    );
    final showModeToggle = sttPref == SttPreference.serverOnly;

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
                if (showModeToggle) ...[
                  const SizedBox(height: 18),
                  _ModeToggle(
                    manual: state.manualEosOnly,
                    onToggle: (v) => session.setManualEosOnly(v),
                  ),
                ],
                const SizedBox(height: 22),
                _ActionRow(
                  state: state,
                  onMicTap: session.tapMicButton,
                  onPauseTap: session.togglePause,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Per-state appearance. One switch produces both the chip flavor (describes
// what the system is doing) and the mic flavor (describes what tapping the
// mic will do). Single source of truth: adding a new state means filling in
// one case, not remembering to update two parallel switches that can drift.
// Pulls from the theme's M3 color roles so the fills stay legible in light
// and dark mode (each container role has a matching on-container role with
// guaranteed contrast).
// =============================================================================

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

/// Constant shorthand for the mic-side appearance when an in-flight turn
/// is interruptible — used by every `thinking`/`speaking` variant.
const IconData _kInterruptIcon = CupertinoIcons.stop_fill;
const String _kInterruptLabel = 'INTERRUPT';

_CallStyle _styleFor(CallSessionState s, ColorScheme cs) {
  if (s.paused) {
    return _CallStyle(
      chipLabel: 'Paused',
      chipIcon: CupertinoIcons.pause_fill,
      chipFill: cs.surfaceContainerHighest,
      chipOnFill: cs.onSurfaceVariant,
      micLabel: 'PAUSED',
      micIcon: CupertinoIcons.pause_fill,
      micFill: cs.outline,
      micOnFill: cs.onPrimary,
    );
  }
  switch (s.step) {
    case CallStep.idle:
      return _CallStyle(
        chipLabel: 'Connecting',
        chipIcon: CupertinoIcons.dot_radiowaves_left_right,
        chipFill: cs.surfaceContainerHighest,
        chipOnFill: cs.onSurfaceVariant,
        micLabel: 'CONNECTING',
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
          micLabel: 'SENDING',
          micIcon: CupertinoIcons.hourglass,
          micFill: cs.tertiary,
          micOnFill: cs.onTertiary,
        );
      }
      return _CallStyle(
        chipLabel: 'Listening',
        chipIcon: CupertinoIcons.waveform,
        chipFill: cs.error,
        chipOnFill: cs.onError,
        micLabel: 'SEND',
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
        micLabel: 'ERROR',
        micIcon: CupertinoIcons.exclamationmark,
        micFill: cs.error,
        micOnFill: cs.onError,
      );
  }
}

// =============================================================================
// Header: status chip on the left, End on the right. Both stay compact so
// the Mic button below is the dominant visual element on the sheet.
// =============================================================================

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.onEndTap});

  final CallSessionState state;
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
  final CallSessionState state;

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
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: cs.error,
          ),
          child: Icon(
            CupertinoIcons.xmark,
            color: cs.onError,
            size: 18,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Live transcript. Visible only once [CallSessionState.sttReady] is true —
// meaning [CallStt.start] has resolved and audio is genuinely flowing. For
// gateway STT that's the "server is connected and listening" moment (WS
// handshake done); for on-device STT it's the recognizer init completing.
// Hidden while paused so the surface doesn't lie about being able to hear.
//
// Self-manages top spacing (16 px) when visible so the AnimatedSize collapse
// carries the gap away with it cleanly.
// =============================================================================

class _Transcript extends StatelessWidget {
  const _Transcript({required this.state});
  final CallSessionState state;

  bool get _visible => state.sttReady && !state.paused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = state.partialTranscript;
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
                        fontWeight:
                            hasText ? FontWeight.w500 : FontWeight.w400,
                        fontStyle:
                            hasText ? FontStyle.normal : FontStyle.italic,
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

// =============================================================================
// Auto / Tap segmented control. Full-width pill, 52px tall — safe to
// operate without looking.
// =============================================================================

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.manual, required this.onToggle});
  final bool manual;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _segment(
              context,
              label: 'Auto send',
              selected: !manual,
              onTap: () {
                if (manual) {
                  HapticFeedback.selectionClick();
                  onToggle(false);
                }
              },
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _segment(
              context,
              label: 'Tap to send',
              selected: manual,
              onTap: () {
                if (!manual) {
                  HapticFeedback.selectionClick();
                  onToggle(true);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: selected ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.22),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: selected ? cs.onPrimary : cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Action row. Pause on the left (48px, secondary), Mic on the right (112px,
// the only button that matters during normal flow). `spaceEvenly` keeps
// them comfortably apart so the thumb can't drift from Mic onto Pause.
// =============================================================================

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.state,
    required this.onMicTap,
    required this.onPauseTap,
  });

  final CallSessionState state;
  final VoidCallback onMicTap;
  final VoidCallback onPauseTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _PauseButton(state: state, onTap: onPauseTap),
        _MicButton(state: state, onTap: onMicTap),
      ],
    );
  }
}

// =============================================================================
// Pause button — 48px secondary. Tap to mute the mic / unmute. Disabled in
// idle and error because there's nothing to mute in those states.
// =============================================================================

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.state, required this.onTap});
  final CallSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final disabled =
        state.step == CallStep.idle || state.step == CallStep.error;
    final paused = state.paused;
    final fill = paused ? cs.primary : cs.surfaceContainerHighest;
    final onFill = paused ? cs.onPrimary : cs.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: paused ? 'Resume mic' : 'Pause mic',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: disabled ? null : onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: disabled ? fill.withValues(alpha: 0.5) : fill,
              ),
              child: Icon(
                paused ? CupertinoIcons.mic_fill : CupertinoIcons.pause_fill,
                size: 24,
                color: onFill,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          paused ? 'RESUME' : 'PAUSE',
          style: theme.textTheme.labelSmall?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Mic button — primary action. 112px, labeled, color-coded to the current
// state so it doubles as a redundant status cue.
// =============================================================================

class _MicButton extends StatelessWidget {
  const _MicButton({required this.state, required this.onTap});
  final CallSessionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = _styleFor(state, cs);
    final disabled = state.paused ||
        state.step == CallStep.idle ||
        state.step == CallStep.error ||
        (state.step == CallStep.listening && state.committing);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: style.micLabel,
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
                color: disabled
                    ? style.micFill.withValues(alpha: 0.5)
                    : style.micFill,
                boxShadow: [
                  BoxShadow(
                    color: style.micFill.withValues(alpha: 0.4),
                    blurRadius: state.step == CallStep.listening ? 28 : 16,
                    spreadRadius: state.step == CallStep.listening ? 4 : 0,
                  ),
                ],
              ),
              child: Icon(style.micIcon, size: 48, color: style.micOnFill),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          style.micLabel,
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
