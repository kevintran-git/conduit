enum RealtimeCallStep { idle, live, error }

class RealtimeCallSessionState {
  const RealtimeCallSessionState({
    this.step = RealtimeCallStep.idle,
    this.connected = false,
    this.speaking = false,
    this.muted = false,
    this.inputTranscript = '',
    this.outputTranscript = '',
    this.errorMessage,
    this.runningTool,
  });

  final RealtimeCallStep step;
  final bool connected;
  final bool speaking;
  final bool muted;
  final String inputTranscript;
  final String outputTranscript;
  final String? errorMessage;
  final String? runningTool;

  RealtimeCallSessionState copyWith({
    RealtimeCallStep? step,
    bool? connected,
    bool? speaking,
    bool? muted,
    String? inputTranscript,
    String? outputTranscript,
    String? errorMessage,
    bool clearError = false,
    String? runningTool,
    bool clearRunningTool = false,
  }) {
    return RealtimeCallSessionState(
      step: step ?? this.step,
      connected: connected ?? this.connected,
      speaking: speaking ?? this.speaking,
      muted: muted ?? this.muted,
      inputTranscript: inputTranscript ?? this.inputTranscript,
      outputTranscript: outputTranscript ?? this.outputTranscript,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      runningTool: clearRunningTool ? null : (runningTool ?? this.runningTool),
    );
  }

  static const RealtimeCallSessionState initial = RealtimeCallSessionState();
}
