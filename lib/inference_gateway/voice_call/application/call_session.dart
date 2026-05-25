import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../core/utils/reasoning_parser.dart';
import '../../../features/chat/providers/chat_providers.dart' as chat;
import '../../config/gateway_providers.dart';
import '../../router/gateway_router_providers.dart';
import '../domain/call_step.dart';
import 'call_stt.dart';
import 'call_tts.dart';

/// The voice call.
///
/// Reads top to bottom: [_runLoop] is the entire conversation, expressed as
/// a `while` loop over four steps — listen, think, speak, wait. No state
/// machine, no callback web. The [CallStep] enum is just a label the UI
/// reads; the loop decides what happens next.
///
/// Cancellation: every long-running await inside a turn races against a
/// per-turn [Completer<void>] called `_cancel`. Tapping the mic button
/// during `thinking` / `speaking` completes it, the in-flight awaits throw
/// [_BargedIn], cleanup runs in `on _BargedIn` / `finally`, and the loop
/// rolls over to the next iteration. That's the whole interruption model.
class CallSession extends Notifier<CallSessionState> {
  CallStt? _stt;
  CallTts? _tts;
  StreamSubscription<bool>? _ttsPlayingSub;
  StreamSubscription<TtsStatus>? _ttsStatusSub;

  /// Broadcast pipe for chat messages updates. Used to detect end-of-stream
  /// (`isStreaming` flips false) so we can flush the TTS WS. Subscribed
  /// permanently in [build] via `ref.listen`, then re-broadcast so
  /// [_thinkAndSpeak] can take an ad-hoc per-turn subscription. (Notifier
  /// `ref` doesn't expose `listenManual` in this Riverpod version.)
  final StreamController<List<ChatMessage>> _chatStream =
      StreamController<List<ChatMessage>>.broadcast();

  /// Broadcast pipe for the live streaming content. Updates every ~100ms
  /// during LLM generation (chatMessagesProvider only rebuilds at end), so
  /// this is the feed we drip-feed into the TTS WS to get speech started
  /// while the LLM is still typing.
  final StreamController<String?> _streamingContentBus =
      StreamController<String?>.broadcast();

  bool _alive = true;
  Completer<void>? _cancel;
  Completer<void>? _resume;

  /// Run of consecutive failed turns. A clean barge-in or completed
  /// think+speak resets it; three strikes ends the loop so we don't
  /// spin forever on a dead network or misconfigured gateway.
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 3;

  @override
  CallSessionState build() {
    ref.onDispose(_teardown);
    unawaited(WakelockPlus.enable());
    ref.read(gatewayInferenceRouterProvider).markCallStart();
    ref.listen<List<ChatMessage>>(
      chat.chatMessagesProvider,
      (prev, next) {
        if (!_chatStream.isClosed) _chatStream.add(next);
      },
    );
    ref.listen<String?>(
      chat.streamingContentProvider,
      (prev, next) {
        if (!_streamingContentBus.isClosed) _streamingContentBus.add(next);
      },
    );
    Future.microtask(_runLoop);
    return CallSessionState(
      manualEosOnly: ref.read(gatewayConfigProvider).voiceManualMode,
    );
  }

  // ===========================================================================
  // Public gestures
  // ===========================================================================

  /// Mic button tap. Context-aware:
  ///   listening → commit the current utterance ([CallStt.requestFinal])
  ///   thinking / speaking → barge in (cancel and loop back to listening)
  ///   idle / error → no-op
  Future<void> tapMicButton() async {
    switch (state.step) {
      case CallStep.listening:
        if (state.committing) return; // already in flight; ignore double-tap
        // Refuse the commit if nothing was heard yet. Acknowledge with a
        // light haptic so the tap doesn't feel ignored, but stay out of the
        // `committing` flash that would otherwise tell the user "sending…"
        // when there's nothing to send.
        if (state.partialTranscript.trim().isEmpty) {
          HapticFeedback.lightImpact();
          return;
        }
        HapticFeedback.mediumImpact();
        state = state.copyWith(committing: true);
        try {
          await _stt?.requestFinal();
        } catch (error) {
          DebugLogger.warning(
            'request-final-failed',
            scope: 'call',
            data: {'error': error.toString()},
          );
          // Reset so the mic isn't permanently disabled. The loop will fall
          // back to whatever the STT decides (likely an empty final via
          // `onDone`, in which case we just continue to the next listen).
          if (state.step == CallStep.listening) {
            state = state.copyWith(committing: false);
          }
        }
        break;
      case CallStep.thinking:
      case CallStep.speaking:
        HapticFeedback.heavyImpact();
        _interrupt();
        break;
      case CallStep.idle:
      case CallStep.error:
        break;
    }
  }

  Future<void> end() async {
    _alive = false;
    _resume?.complete();
    _resume = null;
    _interrupt();
  }

  /// Mute/unmute the mic — "put the call on hold." Resuming clears the flag
  /// and lets the loop fall back into [_listen].
  ///
  /// Pause behavior is intentionally asymmetric by step:
  ///   listening → interrupt the in-flight STT so the mic disconnects now
  ///   thinking / speaking → just set the flag; let the assistant finish
  ///     talking, then the loop's top-of-iteration paused check parks
  ///     before re-entering listen. Pausing should never silence a
  ///     mid-sentence assistant.
  Future<void> togglePause() async {
    HapticFeedback.lightImpact();
    if (state.paused) {
      state = state.copyWith(paused: false);
      _resume?.complete();
      _resume = null;
    } else {
      state = state.copyWith(paused: true);
      _resume = Completer<void>();
      if (state.step == CallStep.listening) _interrupt();
    }
  }

  /// Flip the "manual-EOS only" mode mid-call. State updates immediately so
  /// the overlay rebuilds on tap; STT and config persist behind it.
  Future<void> setManualEosOnly(bool value) async {
    if (state.manualEosOnly == value) return;
    state = state.copyWith(manualEosOnly: value);
    _stt?.manualEosOnly = value;
    final cfg = ref.read(gatewayConfigProvider);
    if (cfg.voiceManualMode != value) {
      await ref.read(gatewayConfigProvider.notifier).setVoiceManualMode(value);
    }
  }

  // ===========================================================================
  // The loop
  // ===========================================================================

  Future<void> _runLoop() async {
    try {
      final ok = await _setup();
      if (!ok) return;
      HapticFeedback.lightImpact();
      while (_alive) {
        if (state.paused) {
          // Defensive: if pause was set without _resume (shouldn't happen,
          // but `await null` would silently no-op), create one now so the
          // wait is guaranteed.
          await (_resume ??= Completer<void>()).future;
          if (!_alive) break;
        }
        _cancel = Completer<void>();
        try {
          final text = await _listen();
          if (!_alive) break;
          if (text.isEmpty) continue;
          await _thinkAndSpeak(text);
          _consecutiveFailures = 0;
        } on _BargedIn {
          // Expected — user interrupted. Loop to next iteration.
          _consecutiveFailures = 0;
        } catch (error, stackTrace) {
          DebugLogger.error(
            'turn-failed',
            scope: 'call',
            error: error,
            stackTrace: stackTrace,
          );
          _consecutiveFailures++;
          final fatal = _isFatalError(error);
          if (fatal || _consecutiveFailures >= _maxConsecutiveFailures) {
            // Surface a real message and stop spinning. The user has to tap
            // End to dismiss — that's deliberate so they see what happened.
            state = state.copyWith(
              step: CallStep.error,
              errorMessage: fatal
                  ? _fatalMessage(error)
                  : 'Couldn\'t connect after $_maxConsecutiveFailures tries. '
                      'Tap End to try again.',
            );
            break;
          }
          state = state.copyWith(
            step: CallStep.error,
            errorMessage: 'Something went wrong. Retrying…',
          );
          // Hold the error briefly so the user sees it, then loop.
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    } finally {
      await _teardown();
    }
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  Future<bool> _setup() async {
    final cfg = ref.read(gatewayConfigProvider);
    if (!cfg.voiceEnabled || !cfg.hasCredentials) {
      _emitError('Voice gateway is not configured.');
      return false;
    }

    final settings = ref.read(appSettingsProvider);
    final pauseFor = Duration(
      milliseconds: settings.voiceSilenceDuration.clamp(
        SettingsService.minVoiceSilenceDurationMs,
        SettingsService.maxVoiceSilenceDurationMs,
      ),
    );

    try {
      if (settings.sttPreference == SttPreference.deviceOnly) {
        _stt = DeviceCallStt(
          pauseFor: pauseFor,
          manualEosOnly: cfg.voiceManualMode,
        );
      } else {
        _stt = GatewayCallStt(
          config: cfg,
          manualEosOnly: cfg.voiceManualMode,
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'stt-init-failed',
        scope: 'call',
        error: error,
        stackTrace: stackTrace,
      );
      _emitError('Could not start speech recognition.');
      return false;
    }

    _tts = CallTts(
      client: ref.read(gatewayElevenLabsClientProvider),
      config: cfg,
    );
    // UI flips to `speaking` the moment real PCM starts decoding.
    _ttsPlayingSub = _tts!.playing.listen((playing) {
      if (!_alive || !playing) return;
      if (state.step == CallStep.thinking) {
        HapticFeedback.lightImpact();
        state = state.copyWith(step: CallStep.speaking);
      }
    });
    // Push every TTS pipeline transition into state so the overlay can
    // render a live "audio incoming • 12 frames" status line.
    _ttsStatusSub = _tts!.statusStream.listen((status) {
      if (!_alive) return;
      state = state.copyWith(tts: status);
    });

    return true;
  }

  // ---------------------------------------------------------------------------
  // Step 1 — LISTEN
  // ---------------------------------------------------------------------------

  Future<String> _listen() async {
    final stt = _stt!;
    state = state.copyWith(
      step: CallStep.listening,
      sttReady: false,
      partialTranscript: '',
      committing: false,
      clearError: true,
    );
    HapticFeedback.mediumImpact();

    try {
      await stt.start();
      // Mic is open; for gateway mode the WS handshake has also completed —
      // this is the "server is listening" signal the overlay uses to decide
      // whether to show the live transcript box.
      state = state.copyWith(sttReady: true);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'stt-start-failed',
        scope: 'call',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    final completer = Completer<String>();
    late StreamSubscription<SttEvent> sub;
    sub = stt.events.listen(
      (event) {
        if (event.isFinal) {
          final text = event.text.trim();
          // Reflect the actual final the user sent in the live transcript
          // for the brief moment before _thinkAndSpeak clears it. If the
          // server refined the text, this lets the user see what was
          // really registered.
          if (state.step == CallStep.listening) {
            state = state.copyWith(partialTranscript: text);
          }
          if (!completer.isCompleted) completer.complete(text);
          return;
        }
        if (state.step == CallStep.listening) {
          state = state.copyWith(partialTranscript: event.text);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: () {
        // STT closed without a final (e.g. WS error). Treat as empty turn.
        if (!completer.isCompleted) completer.complete('');
      },
    );
    _cancel!.future.then((_) {
      if (!completer.isCompleted) completer.completeError(_BargedIn());
    });

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      await stt.stop();
    }
  }

  // ---------------------------------------------------------------------------
  // Steps 2 + 3 + 4 — THINK + SPEAK + WAIT
  // ---------------------------------------------------------------------------

  Future<void> _thinkAndSpeak(String text) async {
    final tts = _tts!;
    state = state.copyWith(
      step: CallStep.thinking,
      sttReady: false,
      partialTranscript: '',
      committing: false,
    );
    HapticFeedback.lightImpact();

    // Fresh TTS session for this response. Fire-and-forget — append/flush
    // buffer text until the WS handshake completes.
    unawaited(tts.open());

    int lastLength = 0;

    // Drip-feed every streaming token into the TTS WS as it lands. This is
    // why the user hears the assistant start speaking long before the LLM
    // finishes generating.
    final streamSub = _streamingContentBus.stream.listen((content) {
      if (content == null || content.isEmpty) return;
      final spoken = _spokenContent(content);
      if (spoken.length > lastLength) {
        tts.append(spoken.substring(lastLength));
        lastLength = spoken.length;
      }
    });

    // chatMessagesProvider only rebuilds at end-of-stream — that's our
    // flush signal. Also picks up any tail content that landed in the final
    // sync but never went through streamingContentProvider.
    final messagesSub = _chatStream.stream.listen((messages) {
      if (messages.isEmpty) return;
      final last = messages.last;
      if (last.role != 'assistant') return;
      if (last.isStreaming) return;
      final spoken = _spokenContent(last.content);
      if (spoken.length > lastLength) {
        tts.append(spoken.substring(lastLength));
        lastLength = spoken.length;
      }
      tts.flush();
    });

    try {
      await _race(
        chat.sendMessageFromService(ref, text, null, null, true),
      );
      // Safety: if the chat provider's final isStreaming=false update
      // hadn't propagated by the time sendMessageFromService returned,
      // flush ourselves. ElevenLabs handles double-flush gracefully.
      tts.flush();
      // No timeout: awaitDrain resolves when the server signals end-of-audio
      // (isFinal:true or WS close). If the server hangs, the user taps the
      // mic button to barge in — _race throws _BargedIn and we recover.
      await _race(tts.awaitDrain());
    } on _BargedIn {
      // User interrupted. Tear down the LLM stream and the TTS playback.
      ref.read(chat.stopGenerationProvider)();
      await tts.stop();
      rethrow;
    } finally {
      await streamSub.cancel();
      await messagesSub.cancel();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Wrap a work future so it races against the per-turn cancellation
  /// signal. If [_cancel] fires first, the returned future throws
  /// [_BargedIn] — `finally`/`on _BargedIn` clauses in the caller do the
  /// actual cleanup.
  Future<T> _race<T>(Future<T> work) {
    final cancel = _cancel;
    if (cancel == null) return work;
    final completer = Completer<T>();
    work.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    cancel.future.then((_) {
      if (!completer.isCompleted) completer.completeError(_BargedIn());
    });
    return completer.future;
  }

  void _interrupt() {
    final c = _cancel;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Errors that won't get better by retrying — OS-level permission denial
  /// and the platform not having STT at all. Message-matched because the
  /// underlying packages throw bare [StateError]s; introducing a typed
  /// exception would mean changing the [CallStt] interface.
  static bool _isFatalError(Object error) {
    final m = error.toString().toLowerCase();
    return m.contains('permission denied') ||
        m.contains('not available') ||
        m.contains('not configured');
  }

  static String _fatalMessage(Object error) {
    final m = error.toString().toLowerCase();
    if (m.contains('permission denied')) {
      return 'Mic access denied. Enable it in Settings to use voice.';
    }
    if (m.contains('not available')) {
      return 'Speech recognition isn\'t available on this device.';
    }
    return 'Voice setup failed. Check the gateway settings.';
  }

  void _emitError(String message) {
    HapticFeedback.heavyImpact();
    state = state.copyWith(step: CallStep.error, errorMessage: message);
  }

  Future<void> _teardown() async {
    _alive = false;
    _interrupt();
    unawaited(WakelockPlus.disable());
    ref.read(gatewayInferenceRouterProvider).markCallEnd();
    // Detach references synchronously so the loop and overlay can't observe
    // stale state. Then fire-and-forget the underlying disposals — the STT
    // recorder and TTS WS handshake can take a few seconds on bad networks,
    // and blocking the dispose path on them causes an Android ANR when the
    // user taps the End button.
    final stt = _stt;
    final tts = _tts;
    final ttsPlayingSub = _ttsPlayingSub;
    final ttsStatusSub = _ttsStatusSub;
    _stt = null;
    _tts = null;
    _ttsPlayingSub = null;
    _ttsStatusSub = null;
    unawaited(() async {
      try {
        await ttsPlayingSub?.cancel();
      } catch (_) {}
      try {
        await ttsStatusSub?.cancel();
      } catch (_) {}
      try {
        await stt?.dispose();
      } catch (_) {}
      try {
        await tts?.dispose();
      } catch (_) {}
    }());
    if (!_chatStream.isClosed) unawaited(_chatStream.close());
    if (!_streamingContentBus.isClosed) {
      unawaited(_streamingContentBus.close());
    }
  }

  /// Drop `<details type="reasoning">` and bare `<think>...</think>` blocks
  /// from an assistant message before piping it to TTS — we never want the
  /// call to speak chain-of-thought.
  static String _spokenContent(String content) {
    if (content.isEmpty) return content;
    if (!content.contains('<details') &&
        !ReasoningParser.hasReasoningContent(content)) {
      return content;
    }
    final segs = ReasoningParser.segments(content);
    if (segs == null || segs.isEmpty) return content;
    final buf = StringBuffer();
    for (final seg in segs) {
      if (seg.isReasoning) continue;
      final text = seg.text;
      if (text != null) buf.write(text);
    }
    return buf.toString();
  }
}

/// Private exception type so the loop can distinguish user-initiated
/// barge-in from real failures.
class _BargedIn implements Exception {
  const _BargedIn();
}

final callSessionProvider =
    NotifierProvider.autoDispose<CallSession, CallSessionState>(
  CallSession.new,
);
