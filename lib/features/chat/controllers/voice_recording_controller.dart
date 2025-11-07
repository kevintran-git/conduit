import 'dart:async';
import 'package:flutter/services.dart';
import '../models/voice_recording_state.dart';
import '../services/voice_input_service.dart';
import '../../../shared/utils/platform_utils.dart';

/// Callback types for voice recording events
typedef OnVoiceStart = Future<void> Function(VoiceRecordingMode mode);
typedef OnVoiceEnd = Future<void> Function();
typedef OnVoiceSubmit = Future<void> Function();
typedef OnPauseVad = void Function();
typedef OnResumeVad = void Function();

/// Unified controller for voice recording interactions
/// Handles all gesture detection, state management, and callbacks
class VoiceRecordingController {
  final VoiceInputService voiceService;
  final OnVoiceStart onVoiceStart;
  final OnVoiceEnd onVoiceEnd;
  final OnVoiceSubmit onVoiceSubmit;
  final OnPauseVad onPauseVad;
  final OnResumeVad onResumeVad;

  Timer? _longPressTimer;
  bool _isPressed = false;
  bool _longPressTriggered = false;
  bool _startedViaLongPress = false; // Track if recording started via long press

  static const Duration initialLongPressDuration = Duration(milliseconds: 400);

  VoiceRecordingController({
    required this.voiceService,
    required this.onVoiceStart,
    required this.onVoiceEnd,
    required this.onVoiceSubmit,
    required this.onPauseVad,
    required this.onResumeVad,
  });

  bool get isPressed => _isPressed;
  
  /// Can use long-press to start paused if server STT is available AND not set to device-only
  bool get canUseLongPress => voiceService.hasServerStt && !voiceService.prefersDeviceOnly;
  
  /// Can pause VAD only when actually using server STT (checked at runtime)
  bool get canPauseVad => voiceService.usingServerStt;

  /// Handle button press down - detects tap vs long press
  void handlePointerDown() {
    _isPressed = true;
    // Detect long press to start in paused mode (only if server STT available)
    if (canUseLongPress) {
      _longPressTimer = Timer(initialLongPressDuration, _handleLongPress);
    }
  }

  /// Handle button release - handles tap-to-start-VAD and release-after-long-press
  void handlePointerUp() {
    _longPressTimer?.cancel();
    _longPressTimer = null;

    final hadLongPress = _longPressTriggered;
    _isPressed = false;

    // If we started via long press and are still holding, release resumes VAD
    if (_startedViaLongPress && hadLongPress) {
      _startedViaLongPress = false;
      _resetState();
      onResumeVad();
      return;
    }

    // If long press triggered but user released before recording started,
    // don't start VAD
    if (hadLongPress) {
      _resetState();
      return;
    }

    // Quick tap - start VAD mode (normal flow)
    _handleQuickTapForVad();
    _resetState();
  }

  /// Handle button cancel (e.g., gesture interrupted)
  void handlePointerCancel() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isPressed = false;
    _longPressTriggered = false;
    _startedViaLongPress = false;
  }

  /// Called when long press detected - starts in VAD paused mode
  void _handleLongPress() {
    _longPressTriggered = true;
    _startedViaLongPress = true;
    HapticFeedback.heavyImpact();
    onVoiceStart(VoiceRecordingMode.vadPaused);
  }

  /// Called when quick tap detected (VAD mode)
  void _handleQuickTapForVad() {
    PlatformUtils.lightHaptic();
    onVoiceStart(VoiceRecordingMode.vad);
  }

  /// Reset internal state
  void _resetState() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isPressed = false;
    _longPressTriggered = false;
  }

  /// Reset long press flag (called when recording ends externally)
  void resetLongPressState() {
    _startedViaLongPress = false;
  }

  void dispose() {
    _longPressTimer?.cancel();
    _resetState();
  }
}

