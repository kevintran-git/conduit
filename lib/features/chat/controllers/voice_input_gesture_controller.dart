import 'dart:async';
import 'package:flutter/services.dart';
import '../models/voice_recording_state.dart';
import '../services/voice_input_service.dart';
import '../../../shared/utils/platform_utils.dart';

/// Callback types
typedef OnVoiceStart = Future<void> Function(VoiceRecordingMode mode);

/// Simplified controller for voice button gestures
/// Only handles initial tap/long-press detection to start recording
/// Once recording starts, VoiceRecordingOverlay handles all gestures
class VoiceInputGestureController {
  final VoiceInputService voiceService;
  final OnVoiceStart onVoiceStart;

  Timer? _longPressTimer;
  bool _isPressed = false;
  bool _longPressTriggered = false;

  static const Duration initialLongPressDuration = Duration(milliseconds: 400);

  VoiceInputGestureController({
    required this.voiceService,
    required this.onVoiceStart,
  });

  bool get isPressed => _isPressed;
  // Can use PTT if server STT is available AND not set to device-only
  bool get canUsePtt => voiceService.hasServerStt && !voiceService.prefersDeviceOnly;
  // Can pause VAD only when actually using server STT (checked at runtime)
  bool get canPauseVad => voiceService.usingServerStt;

  void handlePointerDown() {
    _isPressed = true;
    // Detect long press for PTT (only if server STT available)
    if (canUsePtt) {
      _longPressTimer = Timer(initialLongPressDuration, _handleLongPressForPtt);
    }
    // Otherwise just a quick tap will start VAD
  }

  void handlePointerUp() {
    _longPressTimer?.cancel();
    _longPressTimer = null;

    final hadLongPress = _longPressTriggered;
    _isPressed = false;

    // If long press triggered PTT, don't start VAD
    if (hadLongPress) {
      _resetState();
      return;
    }

    // Quick tap - start VAD mode (normal flow)
    _handleQuickTapForVad();
    _resetState();
  }

  void handlePointerCancel() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isPressed = false;
    _longPressTriggered = false;
  }

  void _handleLongPressForPtt() {
    _longPressTriggered = true;
    HapticFeedback.heavyImpact();
    onVoiceStart(VoiceRecordingMode.ptt);
  }

  void _handleQuickTapForVad() {
    PlatformUtils.lightHaptic();
    onVoiceStart(VoiceRecordingMode.vad);
  }

  void _resetState() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _isPressed = false;
    _longPressTriggered = false;
  }

  void dispose() {
    _longPressTimer?.cancel();
  }
}

