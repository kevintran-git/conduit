import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_utils.dart';
import '../models/voice_recording_state.dart';
import 'package:conduit/l10n/app_localizations.dart';

/// Callback types for voice button interactions
typedef OnVoiceStart = Future<void> Function(VoiceRecordingMode mode);
typedef OnVoiceEnd = Future<void> Function();
typedef OnVoicePauseVad = void Function();
typedef OnVoiceResumeVad = void Function();
typedef OnVoiceSubmit = Future<void> Function();

/// Sophisticated hybrid voice button with VAD, PTT, and pause capabilities
class HybridVoiceButton extends ConsumerStatefulWidget {
  final bool enabled;
  final VoiceRecordingState? recordingState;
  final OnVoiceStart? onVoiceStart;
  final OnVoiceEnd? onVoiceEnd;
  final OnVoicePauseVad? onPauseVad;
  final OnVoiceResumeVad? onResumeVad;
  final OnVoiceSubmit? onSubmit;
  final double size;

  const HybridVoiceButton({
    super.key,
    this.enabled = true,
    this.recordingState,
    this.onVoiceStart,
    this.onVoiceEnd,
    this.onPauseVad,
    this.onResumeVad,
    this.onSubmit,
    this.size = 44.0,
  });

  @override
  ConsumerState<HybridVoiceButton> createState() =>
      _HybridVoiceButtonState();
}

class _HybridVoiceButtonState extends ConsumerState<HybridVoiceButton>
    with SingleTickerProviderStateMixin {
  // Gesture state
  Timer? _longPressTimer;
  bool _isPressed = false;
  bool _longPressTriggered = false;
  bool _holdDuringRecording = false;

  // Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Timing constants
  static const Duration _initialLongPressDuration = Duration(milliseconds: 400);
  static const Duration _holdDuringRecordingThreshold =
      Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HybridVoiceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset gesture state if recording stopped externally
    if (oldWidget.recordingState != null && widget.recordingState == null) {
      _resetGestureState();
    }
  }

  void _resetGestureState() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isPressed = false;
    _longPressTriggered = false;
    _holdDuringRecording = false;
  }

  // ========== Gesture Handling ==========

  void _handleTapDown(TapDownDetails details) {
    if (!widget.enabled) return;

    setState(() {
      _isPressed = true;
    });

    final isRecording = widget.recordingState != null;

    if (!isRecording) {
      // Starting fresh: detect long press for PTT mode
      _longPressTimer = Timer(_initialLongPressDuration, () {
        if (!mounted || !_isPressed) return;
        _handleLongPressInitial();
      });
    } else {
      // During recording in VAD mode: detect hold to pause
      if (widget.recordingState!.isVadMode) {
        _longPressTimer = Timer(_holdDuringRecordingThreshold, () {
          if (!mounted || !_isPressed) return;
          _handleHoldDuringVadRecording();
        });
      }
    }
  }

  void _handleTapUp(TapUpDetails details) {
    if (!widget.enabled) return;

    _longPressTimer?.cancel();
    _longPressTimer = null;

    final wasPressed = _isPressed;
    final hadLongPress = _longPressTriggered;
    final wasHoldingDuringRecording = _holdDuringRecording;

    setState(() {
      _isPressed = false;
    });

    if (!wasPressed) return;

    final isRecording = widget.recordingState != null;

    // Case 1: Release after long press to start PTT mode → stop recording
    if (hadLongPress && isRecording && widget.recordingState!.isPttMode) {
      _handlePttRelease();
      return;
    }

    // Case 2: Release after holding during VAD recording → resume VAD
    if (wasHoldingDuringRecording && isRecording) {
      _handleResumeVadFromHold();
      return;
    }

    // Case 3: Quick tap while recording in VAD mode → submit immediately
    if (isRecording && widget.recordingState!.isVadMode && !hadLongPress) {
      _handleTapToSubmit();
      return;
    }

    // Case 4: Quick tap when not recording → start VAD mode
    if (!isRecording && !hadLongPress) {
      _handleQuickTapToStartVad();
      return;
    }

    // Reset state
    _resetGestureState();
  }

  void _handleTapCancel() {
    _longPressTimer?.cancel();
    _longPressTimer = null;

    // If holding during recording, resume VAD
    if (_holdDuringRecording && widget.recordingState != null) {
      _handleResumeVadFromHold();
    }

    setState(() {
      _isPressed = false;
      _longPressTriggered = false;
      _holdDuringRecording = false;
    });
  }

  // ========== Interaction Handlers ==========

  /// Initial long press before recording → start PTT mode
  void _handleLongPressInitial() {
    setState(() {
      _longPressTriggered = true;
    });

    // Strong haptic for PTT mode activation
    HapticFeedback.heavyImpact();

    widget.onVoiceStart?.call(VoiceRecordingMode.ptt);
  }

  /// Hold during VAD recording → pause VAD
  void _handleHoldDuringVadRecording() {
    setState(() {
      _holdDuringRecording = true;
    });

    // Medium double-pulse haptic for pause
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted && _holdDuringRecording) {
        HapticFeedback.mediumImpact();
      }
    });

    widget.onPauseVad?.call();
  }

  /// Release after holding during VAD → resume VAD
  void _handleResumeVadFromHold() {
    setState(() {
      _holdDuringRecording = false;
    });

    // Light haptic for resume
    PlatformUtils.lightHaptic();

    widget.onResumeVad?.call();
  }

  /// Tap during VAD recording → submit immediately
  void _handleTapToSubmit() {
    // Medium haptic for manual submit
    HapticFeedback.mediumImpact();

    widget.onSubmit?.call();

    _resetGestureState();
  }

  /// Quick tap when not recording → start VAD mode
  void _handleQuickTapToStartVad() {
    // Light haptic for VAD start
    PlatformUtils.lightHaptic();

    widget.onVoiceStart?.call(VoiceRecordingMode.vad);

    _resetGestureState();
  }

  /// Release button in PTT mode → stop recording
  void _handlePttRelease() {
    // Light haptic for PTT stop
    PlatformUtils.lightHaptic();

    widget.onVoiceEnd?.call();

    _resetGestureState();
  }

  // ========== UI Building ==========

  @override
  Widget build(BuildContext context) {
    final isRecording = widget.recordingState != null;
    final recordingMode = widget.recordingState?.mode;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          return _buildButton(
            context,
            isRecording: isRecording,
            mode: recordingMode,
            pulseScale: _pulseAnimation.value,
          );
        },
      ),
    );
  }

  Widget _buildButton(
    BuildContext context, {
    required bool isRecording,
    required VoiceRecordingMode? mode,
    required double pulseScale,
  }) {
    final theme = context.conduitTheme;

    // Determine visual state
    Color backgroundColor;
    Color iconColor;
    Color borderColor;
    IconData icon;
    bool shouldPulse = false;
    List<BoxShadow> shadows = [];

    if (!widget.enabled) {
      // Disabled state
      backgroundColor = theme.surfaceContainerHighest;
      iconColor = theme.textPrimary.withValues(alpha: Alpha.disabled);
      borderColor = theme.cardBorder.withValues(alpha: 0.3);
      icon = Platform.isIOS ? CupertinoIcons.mic : Icons.mic;
    } else if (!isRecording) {
      // Idle state (ready to record)
      backgroundColor = _isPressed
          ? theme.buttonPrimary.withValues(alpha: 0.3)
          : theme.buttonPrimary.withValues(alpha: 0.1);
      iconColor = theme.buttonPrimary;
      borderColor = theme.buttonPrimary.withValues(alpha: 0.6);
      icon = Platform.isIOS ? CupertinoIcons.mic : Icons.mic;
      if (_isPressed) {
        shadows = [
          BoxShadow(
            color: theme.buttonPrimary.withValues(alpha: 0.3),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ];
      }
    } else if (mode == VoiceRecordingMode.ptt) {
      // PTT mode (hold to record)
      backgroundColor = theme.error.withValues(alpha: 0.9);
      iconColor = Colors.white;
      borderColor = theme.error;
      icon = Platform.isIOS ? CupertinoIcons.stop_circle : Icons.stop_circle;
      shadows = [
        BoxShadow(
          color: theme.error.withValues(alpha: 0.4),
          blurRadius: 16,
          spreadRadius: 2,
        ),
      ];
    } else if (mode == VoiceRecordingMode.vadPaused || _holdDuringRecording) {
      // VAD paused (thinking mode)
      backgroundColor = Colors.orange.withValues(alpha: 0.9);
      iconColor = Colors.white;
      borderColor = Colors.orange;
      icon = Platform.isIOS ? CupertinoIcons.pause : Icons.pause;
      shadows = [
        BoxShadow(
          color: Colors.orange.withValues(alpha: 0.4),
          blurRadius: 16,
          spreadRadius: 2,
        ),
      ];
    } else {
      // VAD active mode (listening)
      backgroundColor = Colors.green.withValues(alpha: 0.9);
      iconColor = Colors.white;
      borderColor = Colors.green;
      icon = Platform.isIOS ? CupertinoIcons.mic : Icons.mic;
      shouldPulse = true;
      shadows = [
        BoxShadow(
          color: Colors.green.withValues(alpha: 0.4),
          blurRadius: 16,
          spreadRadius: 2,
        ),
      ];
    }

    final scale = shouldPulse ? pulseScale : 1.0;

    return Tooltip(
      message: _getTooltipMessage(isRecording, mode),
      child: Transform.scale(
        scale: _isPressed ? 0.95 : scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: backgroundColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: borderColor,
              width: 2.0,
            ),
            boxShadow: shadows,
          ),
          child: Center(
            child: Icon(
              icon,
              size: widget.size * 0.5,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }

  String _getTooltipMessage(bool isRecording, VoiceRecordingMode? mode) {
    final l10n = AppLocalizations.of(context);
    if (!widget.enabled) {
      return l10n?.voiceInput ?? 'Voice input unavailable';
    }
    if (!isRecording) {
      return 'Tap: VAD mode | Hold: PTT mode';
    }
    if (mode == VoiceRecordingMode.ptt) {
      return 'Release to stop';
    }
    if (mode == VoiceRecordingMode.vadPaused || _holdDuringRecording) {
      return 'VAD paused - Release to resume';
    }
    return 'Tap: Submit now | Hold: Pause VAD';
  }
}

