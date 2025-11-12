import 'dart:async';
import 'dart:collection';

import 'package:audioplayers/audioplayers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/background_streaming_handler.dart';
import '../../../core/services/socket_service.dart';
import '../../../core/utils/markdown_to_text.dart';
import '../providers/chat_providers.dart';
import 'text_to_speech_service.dart';
import '../../../core/services/settings_service.dart';
import 'voice_input_service.dart';
import 'voice_call_notification_service.dart';

part 'voice_call_service.g.dart';

enum VoiceCallState {
  idle,
  connecting,
  listening,
  paused,
  processing,
  speaking,
  error,
  disconnected,
}

enum VoiceCallPauseReason { user, mute, system }

class VoiceCallService {
  static const String _voiceCallStreamId = 'voice-call';

  final VoiceInputService _voiceInput;
  final TextToSpeechService _tts;
  final SocketService _socketService;
  final Ref _ref;
  final VoiceCallNotificationService _notificationService =
      VoiceCallNotificationService();

  VoiceCallState _state = VoiceCallState.idle;
  String? _sessionId;
  StreamSubscription<String>? _transcriptSubscription;
  StreamSubscription<int>? _intensitySubscription;
  String _accumulatedTranscript = '';
  bool _isDisposed = false;
  bool _isMuted = false;
  bool _listeningPaused = false;
  final Set<VoiceCallPauseReason> _pauseReasons = <VoiceCallPauseReason>{};
  SocketEventSubscription? _socketSubscription;
  Timer? _keepAliveTimer;
  final ListQueue<String> _speechQueue = ListQueue<String>();
  int _enqueuedSentenceCount = 0;
  String? _activeAssistantMessageId;
  bool _responseCompleted = false;
  bool _listeningSuspendedForSpeech = false;
  final Map<int, SpeechAudioChunk> _serverAudioBuffer = {};
  final AudioPlayer _serverAudioPlayer = AudioPlayer();
  int _serverAudioSession = 0;
  int _pendingServerAudioFetches = 0;
  bool _serverPipelineActive = false;
  int _nextServerChunkId = 0;
  int _nextServerPlaybackId = 0;

  final StreamController<VoiceCallState> _stateController =
      StreamController<VoiceCallState>.broadcast();
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();
  final StreamController<String> _responseController =
      StreamController<String>.broadcast();
  final StreamController<int> _intensityController =
      StreamController<int>.broadcast();

  VoiceCallService({
    required VoiceInputService voiceInput,
    required TextToSpeechService tts,
    required SocketService socketService,
    required Ref ref,
  }) : _voiceInput = voiceInput,
       _tts = tts,
       _socketService = socketService,
       _ref = ref {
    _tts.bindHandlers(
      onStart: _handleTtsStart,
      onComplete: _handleTtsComplete,
      onError: _handleTtsError,
      // sentence/word callbacks are not required for call UI, but harmless
    );

    _serverAudioPlayer.onPlayerComplete.listen((_) {
      _handleServerAudioComplete();
    });

    unawaited(_tts.preloadServerDefaults());

    // Set up notification action handler
    _notificationService.onActionPressed = _handleNotificationAction;
  }

  VoiceCallState get state => _state;
  Stream<VoiceCallState> get stateStream => _stateController.stream;
  Stream<String> get transcriptStream => _transcriptController.stream;
  Stream<String> get responseStream => _responseController.stream;
  Stream<int> get intensityStream => _intensityController.stream;

  Future<void> initialize() async {
    if (_isDisposed) return;

    _pauseReasons.clear();
    _listeningPaused = false;

    // Initialize notification service
    await _notificationService.initialize();

    // Request notification permissions if needed
    final notificationsEnabled = await _notificationService
        .areNotificationsEnabled();
    if (!notificationsEnabled) {
      await _notificationService.requestPermissions();
    }

    // Initialize voice input
    final voiceInitialized = await _voiceInput.initialize();
    if (!voiceInitialized) {
      _updateState(VoiceCallState.error);
      throw Exception('Voice input initialization failed');
    }

    // Check if preferred STT path is available
    final hasLocalStt = _voiceInput.hasLocalStt;
    final hasServerStt = _voiceInput.hasServerStt;
    final ready = switch (_voiceInput.preference) {
      SttPreference.deviceOnly => hasLocalStt,
      SttPreference.serverOnly => hasServerStt,
      SttPreference.auto => hasLocalStt || hasServerStt,
    };

    if (!ready) {
      _updateState(VoiceCallState.error);
      throw Exception('Preferred speech recognition engine is unavailable');
    }

    // Check microphone permissions
    final hasMicPermission = await _voiceInput.checkPermissions();
    if (!hasMicPermission) {
      _updateState(VoiceCallState.error);
      throw Exception('Microphone permission not granted');
    }

    // Initialize TTS with current app settings (engine/voice/rate/pitch/volume)
    final settings = _ref.read(appSettingsProvider);
    await _tts.initialize(
      deviceVoice: settings.ttsVoice,
      serverVoice: settings.ttsServerVoiceId,
      speechRate: settings.ttsSpeechRate,
      pitch: settings.ttsPitch,
      volume: settings.ttsVolume,
      engine: settings.ttsEngine,
    );
  }

  Future<void> startCall(String? conversationId) async {
    if (_isDisposed) return;

    try {
      // Update state (this will trigger notification)
      _updateState(VoiceCallState.connecting);

      // Enable wake lock to keep screen on and prevent audio interruption
      await WakelockPlus.enable();

      // Ensure socket connection
      await _socketService.ensureConnected();
      _sessionId = _socketService.sessionId;

      if (_sessionId == null) {
        throw Exception('Failed to establish socket connection');
      }

      await BackgroundStreamingHandler.instance.startBackgroundExecution(const [
        _voiceCallStreamId,
      ], requiresMicrophone: true);

      // Set up periodic keep-alive to refresh wake lock (every 5 minutes)
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => BackgroundStreamingHandler.instance.keepAlive(),
      );

      // Set up socket event listener for assistant responses
      _socketSubscription = _socketService.addChatEventHandler(
        conversationId: conversationId,
        sessionId: _sessionId,
        requireFocus: false,
        handler: _handleSocketEvent,
      );

      // Start listening for user voice input
      await _startListening();
    } catch (e) {
      _updateState(VoiceCallState.error);
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      await WakelockPlus.disable();
      await _notificationService.cancelNotification();
      await BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
        _voiceCallStreamId,
      ]);
      rethrow;
    }
  }

  Future<void> _startListening() async {
    if (_isDisposed) return;

    try {
      _speechQueue.clear();
      _enqueuedSentenceCount = 0;
      _activeAssistantMessageId = null;
      _responseCompleted = false;
      _listeningSuspendedForSpeech = false;
      _resetServerAudio(stopPlayback: true);

      if (_pauseReasons.isNotEmpty) {
        _listeningPaused = true;
        if (_state != VoiceCallState.paused) {
          _updateState(VoiceCallState.paused);
        }
        return;
      }

      _listeningPaused = false;
      _accumulatedTranscript = '';

      final hasLocalStt = _voiceInput.hasLocalStt;
      final hasServerStt = _voiceInput.hasServerStt;
      final pref = _voiceInput.preference;
      final engineAvailable = switch (pref) {
        SttPreference.deviceOnly => hasLocalStt,
        SttPreference.serverOnly => hasServerStt,
        SttPreference.auto => hasLocalStt || hasServerStt,
      };

      if (!engineAvailable) {
        _updateState(VoiceCallState.error);
        throw Exception('Preferred speech recognition engine is unavailable');
      }

      _updateState(VoiceCallState.listening);

      final stream = await _voiceInput.beginListening();

      _transcriptSubscription = stream.listen(
        (text) {
          if (_isDisposed) return;
          _accumulatedTranscript = text;
          _transcriptController.add(text);
        },
        onError: (error) {
          if (_isDisposed) return;
          _updateState(VoiceCallState.error);
        },
        onDone: () async {
          if (_isDisposed) return;
          // User stopped speaking, send message to assistant
          if (_accumulatedTranscript.trim().isNotEmpty) {
            await _sendMessageToAssistant(_accumulatedTranscript);
          } else {
            // No input, restart listening
            await _startListening();
          }
        },
      );

      // Forward intensity stream for waveform visualization
      _intensitySubscription = _voiceInput.intensityStream.listen((intensity) {
        if (_isDisposed) return;
        _intensityController.add(intensity);
      });
    } catch (e) {
      _updateState(VoiceCallState.error);
      rethrow;
    }
  }

  Future<void> _sendMessageToAssistant(String text) async {
    if (_isDisposed) return;

    try {
      _updateState(VoiceCallState.processing);
      _accumulatedResponse = ''; // Reset response accumulator

      // Send message using the existing chat infrastructure
      sendMessageFromService(_ref, text, null);
    } catch (e) {
      _updateState(VoiceCallState.error);
      rethrow;
    }
  }

  String _accumulatedResponse = '';
  bool _isSpeaking = false;
  bool get _hasPendingSpeech {
    if (_serverPipelineActive) {
      return _isSpeaking ||
          _serverAudioBuffer.isNotEmpty ||
          _pendingServerAudioFetches > 0;
    }
    return _isSpeaking || _speechQueue.isNotEmpty;
  }

  void _handleSocketEvent(
    Map<String, dynamic> event,
    void Function(dynamic response)? ack,
  ) {
    if (_isDisposed) return;

    final outerData = event['data'];
    final messageId = event['message_id']?.toString();

    if (outerData is Map<String, dynamic>) {
      final eventType = outerData['type']?.toString();
      final innerData = outerData['data'];

      if (eventType == 'chat:completion' && innerData is Map<String, dynamic>) {
        final bool doneFlag = innerData['done'] == true;
        if (messageId != null && messageId.isNotEmpty) {
          _handleAssistantMessageStart(messageId);
        }

        // Handle full content replacement (used by some models/backends)
        if (innerData.containsKey('content')) {
          final content = innerData['content']?.toString() ?? '';
          if (content.isNotEmpty) {
            _accumulatedResponse = content;
            _responseController.add(content);
            _processSpeakableSegments(isFinalChunk: doneFlag);
            if (doneFlag) {
              _responseCompleted = true;
              _maybeResumeListeningAfterSpeech();
            }
          } else if (doneFlag) {
            _responseCompleted = true;
            _maybeResumeListeningAfterSpeech();
          }
        }

        // Handle streaming delta chunks (incremental updates)
        if (innerData.containsKey('choices')) {
          final choices = innerData['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final firstChoice = choices[0] as Map<String, dynamic>?;
            final delta = firstChoice?['delta'];
            final finishReason = firstChoice?['finish_reason'];

            // Extract incremental content from delta
            if (delta is Map<String, dynamic>) {
              final deltaContent = delta['content']?.toString() ?? '';
              if (deltaContent.isNotEmpty) {
                _accumulatedResponse += deltaContent;
                _responseController.add(_accumulatedResponse);
                _processSpeakableSegments(isFinalChunk: false);
              }
            }

            // Check for completion
            if (finishReason == 'stop' || finishReason == 'length') {
              _responseCompleted = true;
              _processSpeakableSegments(isFinalChunk: true);
              _maybeResumeListeningAfterSpeech();
            }
          }
        }

        if (doneFlag && !_responseCompleted) {
          _responseCompleted = true;
          _processSpeakableSegments(isFinalChunk: true);
          _maybeResumeListeningAfterSpeech();
        }
      }
    }
  }

  void _handleAssistantMessageStart(String messageId) {
    if (_activeAssistantMessageId == messageId) {
      return;
    }
    _activeAssistantMessageId = messageId;
    _accumulatedResponse = '';
    _responseController.add('');
    _speechQueue.clear();
    _enqueuedSentenceCount = 0;
    _responseCompleted = false;
    _resetServerAudio(stopPlayback: true);
    if (_isSpeaking) {
      _isSpeaking = false;
      unawaited(_tts.stop());
    }
  }

  void _processSpeakableSegments({required bool isFinalChunk}) {
    if (_isDisposed) return;
    final cleanText = MarkdownToText.convert(_accumulatedResponse).trim();
    if (cleanText.isEmpty) {
      return;
    }

    final segments = _tts.splitTextForSpeech(cleanText);
    if (segments.isEmpty) {
      return;
    }

    var availableCount = segments.length;
    if (!isFinalChunk && availableCount > 0) {
      availableCount -= 1;
    }
    if (availableCount < 0) {
      availableCount = 0;
    }

    if (_enqueuedSentenceCount > availableCount) {
      _enqueuedSentenceCount = availableCount;
    }

    if (availableCount > _enqueuedSentenceCount) {
      final newChunks = segments.sublist(
        _enqueuedSentenceCount,
        availableCount,
      );
      _enqueuedSentenceCount = availableCount;
      for (final chunk in newChunks) {
        _enqueueSpeechChunk(chunk);
      }
    }

    if (isFinalChunk && _enqueuedSentenceCount < segments.length) {
      _enqueuedSentenceCount = segments.length;
      _enqueueSpeechChunk(segments.last);
    }
  }

  void _enqueueSpeechChunk(String chunk) {
    if (_isDisposed) return;
    final trimmed = chunk.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (_isMuted) {
      return; // Skip playback while muted
    }
    if (_tts.prefersServerEngine) {
      _serverPipelineActive = true;
      final chunkId = _nextServerChunkId++;
      _prefetchServerAudio(trimmed, chunkId);
      return;
    }
    _speechQueue.add(trimmed);
    if (!_isSpeaking) {
      unawaited(_startNextSpeechChunk());
    }
  }

  Future<void> _startNextSpeechChunk() async {
    if (_isDisposed) return;
    if (_speechQueue.isEmpty || _isSpeaking || _isMuted) {
      return;
    }

    final next = _speechQueue.removeFirst();
    try {
      await _prepareForSpeechPlayback();
      _isSpeaking = true;
      _updateState(VoiceCallState.speaking);
      await _tts.speak(next);
    } catch (e) {
      _isSpeaking = false;
      _updateState(VoiceCallState.error);
      unawaited(_startListening());
    }
  }

  void _prefetchServerAudio(String chunk, int chunkId) {
    if (_isDisposed) {
      return;
    }
    final session = _serverAudioSession;
    _pendingServerAudioFetches++;
    _tts
        .synthesizeServerSpeechChunk(chunk)
        .then((audioChunk) {
          _pendingServerAudioFetches--;
          if (_pendingServerAudioFetches < 0) {
            _pendingServerAudioFetches = 0;
          }
          if (_isDisposed ||
              !_serverPipelineActive ||
              session != _serverAudioSession) {
            return;
          }
          _serverAudioBuffer[chunkId] = audioChunk;
          _maybeStartServerAudio();
        })
        .catchError((error, _) {
          _pendingServerAudioFetches--;
          if (_pendingServerAudioFetches < 0) {
            _pendingServerAudioFetches = 0;
          }
          if (_isDisposed) {
            return;
          }
          _handleTtsError(error.toString());
        });
  }

  void _maybeStartServerAudio() {
    if (_isDisposed || !_serverPipelineActive) {
      return;
    }
    if (_isSpeaking || _isMuted) {
      return;
    }
    final chunk = _serverAudioBuffer.remove(_nextServerPlaybackId);
    if (chunk == null) {
      return;
    }
    _nextServerPlaybackId++;
    _playServerAudioChunk(chunk);
  }

  Future<void> _playServerAudioChunk(SpeechAudioChunk chunk) async {
    try {
      await _prepareForSpeechPlayback();
      _isSpeaking = true;
      _updateState(VoiceCallState.speaking);
      await _serverAudioPlayer.play(
        BytesSource(chunk.bytes, mimeType: chunk.mimeType),
      );
    } catch (e) {
      _isSpeaking = false;
      _handleTtsError(e.toString());
    }
  }

  void _handleServerAudioComplete() {
    if (_isDisposed) {
      return;
    }
    _isSpeaking = false;
    if (_serverAudioBuffer.containsKey(_nextServerPlaybackId)) {
      _maybeStartServerAudio();
      return;
    }
    _maybeResumeListeningAfterSpeech();
  }

  void _resetServerAudio({bool stopPlayback = false}) {
    _serverAudioBuffer.clear();
    _pendingServerAudioFetches = 0;
    _serverAudioSession++;
    _nextServerChunkId = 0;
    _nextServerPlaybackId = 0;
    if (stopPlayback) {
      unawaited(_serverAudioPlayer.stop());
      _isSpeaking = false;
    }
    _serverPipelineActive = false;
  }

  Future<void> _prepareForSpeechPlayback() async {
    if (_listeningSuspendedForSpeech) {
      return;
    }
    _listeningSuspendedForSpeech = true;
    await _voiceInput.stopListening();
    await _transcriptSubscription?.cancel();
    _transcriptSubscription = null;
    await _intensitySubscription?.cancel();
    _intensitySubscription = null;
  }

  void _maybeResumeListeningAfterSpeech() {
    if (!_responseCompleted) {
      return;
    }
    if (_hasPendingSpeech) {
      return;
    }

    if (_pauseReasons.isNotEmpty) {
      _listeningPaused = true;
      if (_state != VoiceCallState.paused) {
        _updateState(VoiceCallState.paused);
      }
      return;
    }

    if (_serverPipelineActive && _pendingServerAudioFetches > 0) {
      return;
    }

    unawaited(_startListening());
  }

  void _handleTtsStart() {
    if (_isDisposed) return;
    _updateState(VoiceCallState.speaking);
  }

  void _handleTtsComplete() {
    if (_isDisposed) return;
    _isSpeaking = false;
    if (_speechQueue.isNotEmpty) {
      unawaited(_startNextSpeechChunk());
      return;
    }
    _maybeResumeListeningAfterSpeech();
  }

  void _handleTtsError(String error) {
    if (_isDisposed) return;
    _isSpeaking = false;
    _speechQueue.clear();
    _resetServerAudio(stopPlayback: true);
    _listeningSuspendedForSpeech = false;
    _updateState(VoiceCallState.error);
    // Try to recover by restarting listening
    _startListening();
  }

  Future<void> stopCall() async {
    if (_isDisposed) return;

    // Cancel keep-alive timer
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    await _transcriptSubscription?.cancel();
    await _intensitySubscription?.cancel();
    _socketSubscription?.dispose();

    await _voiceInput.stopListening();
    await _tts.stop();
    await _serverAudioPlayer.stop();

    await BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
      _voiceCallStreamId,
    ]);

    // Cancel notification
    await _notificationService.cancelNotification();

    // Disable wake lock when call ends
    await WakelockPlus.disable();

    _sessionId = null;
    _accumulatedTranscript = '';
    _isMuted = false;
    _listeningPaused = false;
    _pauseReasons.clear();
    _speechQueue.clear();
    _enqueuedSentenceCount = 0;
    _responseCompleted = false;
    _listeningSuspendedForSpeech = false;
    _activeAssistantMessageId = null;
    _isSpeaking = false;
    _resetServerAudio(stopPlayback: true);
    _updateState(VoiceCallState.disconnected);
  }

  Future<void> pauseListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) async {
    if (_isDisposed) return;

    final wasEmpty = _pauseReasons.isEmpty;
    _pauseReasons.add(reason);
    if (!wasEmpty) {
      return;
    }

    _listeningPaused = true;
    await _voiceInput.stopListening();
    await _transcriptSubscription?.cancel();
    await _intensitySubscription?.cancel();

    if (_state == VoiceCallState.listening) {
      _updateState(VoiceCallState.paused);
    }
  }

  Future<void> resumeListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) async {
    if (_isDisposed) return;

    _pauseReasons.remove(reason);
    if (_pauseReasons.isNotEmpty) {
      return;
    }

    if (_state == VoiceCallState.paused || _listeningPaused) {
      await _startListening();
    }
  }

  Future<void> cancelSpeaking() async {
    if (_isDisposed) return;
    _speechQueue.clear();
    _enqueuedSentenceCount = 0;
    _responseCompleted = false;
    _listeningSuspendedForSpeech = false;
    _resetServerAudio(stopPlayback: true);
    await _tts.stop();
    _isSpeaking = false;
    _accumulatedResponse = '';
    // Immediately restart listening
    await _startListening();
  }

  void _updateState(VoiceCallState newState) {
    if (_isDisposed) return;
    _state = newState;
    _stateController.add(newState);

    // Update notification when state changes (fire and forget)
    _updateNotification().catchError((e) {
      // Ignore notification errors
    });
  }

  Future<void> _updateNotification() async {
    // Skip notification for idle, error, and disconnected states
    if (_state == VoiceCallState.idle ||
        _state == VoiceCallState.error ||
        _state == VoiceCallState.disconnected) {
      return;
    }

    try {
      final selectedModel = _ref.read(selectedModelProvider);
      final modelName = selectedModel?.name ?? 'Assistant';

      await _notificationService.updateCallStatus(
        modelName: modelName,
        isMuted: _isMuted,
        isSpeaking: _state == VoiceCallState.speaking,
        isPaused:
            _state == VoiceCallState.paused ||
            (_pauseReasons.isNotEmpty && !_isSpeaking),
      );
    } catch (e) {
      // Silently ignore notification errors
    }
  }

  void _handleNotificationAction(String action) {
    switch (action) {
      case 'mute_call':
        _toggleMute();
        break;
      case 'unmute_call':
        _toggleMute();
        break;
      case 'end_call':
        stopCall();
        break;
    }
  }

  void _toggleMute() {
    _isMuted = !_isMuted;
    if (_isMuted) {
      if (_isSpeaking) {
        unawaited(_tts.stop());
        _isSpeaking = false;
        _accumulatedResponse = '';
      }
      _speechQueue.clear();
      _enqueuedSentenceCount = 0;
      _responseCompleted = false;
      _listeningSuspendedForSpeech = false;
      _resetServerAudio(stopPlayback: true);
      pauseListening(reason: VoiceCallPauseReason.mute);
    } else {
      resumeListening(reason: VoiceCallPauseReason.mute);
    }
    _updateNotification();
  }

  Future<void> dispose() async {
    _isDisposed = true;

    // Cancel keep-alive timer
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    await _transcriptSubscription?.cancel();
    await _intensitySubscription?.cancel();
    _socketSubscription?.dispose();

    _voiceInput.dispose();
    await _tts.dispose();
    await _serverAudioPlayer.dispose();

    // Cancel notification
    await _notificationService.cancelNotification();

    // Ensure wake lock is disabled on dispose
    await WakelockPlus.disable();

    await BackgroundStreamingHandler.instance.stopBackgroundExecution(const [
      _voiceCallStreamId,
    ]);

    await _stateController.close();
    await _transcriptController.close();
    await _responseController.close();
    await _intensityController.close();
  }
}

@Riverpod(keepAlive: true)
VoiceCallService voiceCallService(Ref ref) {
  final voiceInput = ref.watch(voiceInputServiceProvider);
  final api = ref.watch(apiServiceProvider);
  final tts = TextToSpeechService(api: api);
  final socketService = ref.watch(socketServiceProvider);

  if (socketService == null) {
    throw Exception('Socket service not available');
  }

  final service = VoiceCallService(
    voiceInput: voiceInput,
    tts: tts,
    socketService: socketService,
    ref: ref,
  );

  // Keep TTS settings in sync with app settings during a call
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    // Update voice/engine and runtime parameters
    service._tts.updateSettings(
      voice: next.ttsVoice,
      serverVoice: next.ttsServerVoiceId,
      speechRate: next.ttsSpeechRate,
      pitch: next.ttsPitch,
      volume: next.ttsVolume,
      engine: next.ttsEngine,
    );
  });

  ref.onDispose(() {
    service.dispose();
  });

  return service;
}
