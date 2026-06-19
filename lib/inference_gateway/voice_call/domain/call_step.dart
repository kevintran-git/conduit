import '../application/call_tts.dart';

/// The four steps of a voice conversation, plus idle/error for UI bookkeeping.
///
/// Not a state machine. Just a label the [CallSession] writes at the top of
/// each step so the UI can render the right pill/color. The loop's
/// `_runTurn` decides what happens next — the enum doesn't.
enum CallStep { idle, listening, thinking, speaking, error }

/// Immutable snapshot the overlay reads.
class CallSessionState {
  const CallSessionState({
    this.step = CallStep.idle,
    this.sttReady = false,
    this.partialTranscript = '',
    this.tts = TtsStatus.idle,
    this.committing = false,
    this.manualEosOnly = false,
    this.paused = false,
    this.errorMessage,
  });

  final CallStep step;

  /// True once [CallStt.start] has resolved for the current listen phase —
  /// meaning the mic is open and (for gateway STT) the WebSocket handshake
  /// to the server has completed. Flips back to false at the start of each
  /// new listen phase, before [CallStt.start] is awaited again.
  ///
  /// This is the "server is listening" signal: it lags [CallStep.listening]
  /// by the WS connection time on gateway mode, or by the device recognizer
  /// init time on first use, but it's a genuine "audio is flowing" indicator
  /// rather than a side-effect proxy like [partialTranscript].
  final bool sttReady;

  /// What the user said this turn. Updates live as STT emits partials
  /// during [CallStep.listening], then gets replaced by the final
  /// transcript the instant it arrives — so what's on screen is literally
  /// what was sent. Persists through thinking / speaking so the user can
  /// verify what was registered. Cleared at the start of the next listen.
  final String partialTranscript;

  /// Live TTS pipeline state — surfaced to the UI as a small status line
  /// during [CallStep.thinking] / [CallStep.speaking] so the user can see
  /// whether audio is incoming, buffering, etc.
  final TtsStatus tts;

  /// True between the user tapping the mic to manually send and the
  /// final transcript landing. Lets the UI show "Sending…" instead of
  /// "Listening…" so the tap feels instant.
  final bool committing;

  /// Manual-EOS mode: only the mic tap commits an utterance (no automatic
  /// silence-triggered finalization). Surfaced through state so the overlay
  /// rebuilds instantly when the toggle is flipped.
  final bool manualEosOnly;

  /// User-toggled mute: STT is torn down and the loop holds before re-entering
  /// listen. Tap the pause button again to resume.
  final bool paused;

  /// Set together with [CallStep.error]. Null in every other step.
  final String? errorMessage;

  CallSessionState copyWith({
    CallStep? step,
    bool? sttReady,
    String? partialTranscript,
    TtsStatus? tts,
    bool? committing,
    bool? manualEosOnly,
    bool? paused,
    String? errorMessage,
    bool clearError = false,
  }) {
    return CallSessionState(
      step: step ?? this.step,
      sttReady: sttReady ?? this.sttReady,
      partialTranscript: partialTranscript ?? this.partialTranscript,
      tts: tts ?? this.tts,
      committing: committing ?? this.committing,
      manualEosOnly: manualEosOnly ?? this.manualEosOnly,
      paused: paused ?? this.paused,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  static const CallSessionState initial = CallSessionState();
}
