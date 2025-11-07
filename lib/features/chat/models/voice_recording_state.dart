/// Voice recording mode determines the interaction model
enum VoiceRecordingMode {
  /// Voice Activity Detection mode - hands-free, auto-stops after silence
  vad,

  /// Push-to-Talk mode - must hold button to record
  ptt,

  /// VAD temporarily paused while user holds button (still recording, just won't auto-stop)
  vadPaused,

  /// Recording stopped, transcribing/sending to server
  processing,
}

/// Complete state of an active voice recording session
class VoiceRecordingState {
  final VoiceRecordingMode mode;
  final DateTime startTime;
  final bool hasDetectedSpeech;

  const VoiceRecordingState({
    required this.mode,
    required this.startTime,
    this.hasDetectedSpeech = false,
  });

  Duration get duration => DateTime.now().difference(startTime);

  bool get isVadMode => mode == VoiceRecordingMode.vad;
  bool get isPttMode => mode == VoiceRecordingMode.ptt;
  bool get isVadPaused => mode == VoiceRecordingMode.vadPaused;
  bool get isProcessing => mode == VoiceRecordingMode.processing;

  VoiceRecordingState copyWith({
    VoiceRecordingMode? mode,
    DateTime? startTime,
    bool? hasDetectedSpeech,
  }) {
    return VoiceRecordingState(
      mode: mode ?? this.mode,
      startTime: startTime ?? this.startTime,
      hasDetectedSpeech: hasDetectedSpeech ?? this.hasDetectedSpeech,
    );
  }
}

