import 'dart:async';
import 'dart:ui';
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

  // State
  VoiceCallState _state = VoiceCallState.idle;
  String? _sessionId;
  bool _isDisposed = false;
  
  // Pause management
  final Set<VoiceCallPauseReason> _pauseReasons = <VoiceCallPauseReason>{};
  
  // Subscriptions
  StreamSubscription<String>? _transcriptSubscription;
  StreamSubscription<int>? _intensitySubscription;
  SocketEventSubscription? _socketSubscription;
  Timer? _keepAliveTimer;

  // User input
  String _currentTranscript = '';
  
  // Response streaming
  int _messageGeneration = 0;
  String _streamingResponse = '';
  bool _responseComplete = false;
  final List<String> _sentencesToSpeak = [];
  int _sentencesProcessed = 0;
  
  // TTS state
  bool _isSpeaking = false;
  
  // Background streaming (muted state - LLM streams while user prepares response)
  bool _isBackgroundStreaming = false;
  bool _manualSendPending = false;
  
  // VAD pause
  bool _vadPaused = false;
  
  // Haptic callback
  VoidCallback? _onResponseChunk;

  // Broadcast streams
  final StreamController<VoiceCallState> _stateController =
      StreamController<VoiceCallState>.broadcast();
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();
  final StreamController<String> _responseController =
      StreamController<String>.broadcast();
  final StreamController<int> _intensityController =
      StreamController<int>.broadcast();
  final StreamController<bool> _vadPausedController =
      StreamController<bool>.broadcast();

  VoiceCallService({
    required VoiceInputService voiceInput,
    required TextToSpeechService tts,
    required SocketService socketService,
    required Ref ref,
  })  : _voiceInput = voiceInput,
        _tts = tts,
        _socketService = socketService,
        _ref = ref {
    _tts.bindHandlers(
      onStart: _onTtsStart,
      onComplete: _onTtsComplete,
      onError: _onTtsError,
    );
    _notificationService.onActionPressed = _handleNotificationAction;
  }

  // Getters
  VoiceCallState get state => _state;
  Stream<VoiceCallState> get stateStream => _stateController.stream;
  Stream<String> get transcriptStream => _transcriptController.stream;
  Stream<String> get responseStream => _responseController.stream;
  Stream<int> get intensityStream => _intensityController.stream;
  bool get isVadPaused => _vadPaused;
  Stream<bool> get vadPausedStream => _vadPausedController.stream;

  void setResponseChunkCallback(VoidCallback? callback) {
    _onResponseChunk = callback;
  }

  // ============================================================================
  // Initialization
  // ============================================================================

  Future<void> initialize() async {
    if (_isDisposed) return;
    
    _pauseReasons.clear();

    await _notificationService.initialize();
    final notificationsEnabled = await _notificationService.areNotificationsEnabled();
    if (!notificationsEnabled) {
      await _notificationService.requestPermissions();
    }

    final voiceInitialized = await _voiceInput.initialize();
    if (!voiceInitialized) {
      _updateState(VoiceCallState.error);
      throw Exception('Voice input initialization failed');
    }

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

    final hasMicPermission = await _voiceInput.checkPermissions();
    if (!hasMicPermission) {
      _updateState(VoiceCallState.error);
      throw Exception('Microphone permission not granted');
    }

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

  // ============================================================================
  // Call lifecycle
  // ============================================================================

  Future<void> startCall(String? conversationId) async {
    if (_isDisposed) return;

    try {
      _updateState(VoiceCallState.connecting);
      await WakelockPlus.enable();

      await _socketService.ensureConnected();
      _sessionId = _socketService.sessionId;
      if (_sessionId == null) {
        throw Exception('Failed to establish socket connection');
      }

      await BackgroundStreamingHandler.instance.startBackgroundExecution(
        const [_voiceCallStreamId],
        requiresMicrophone: true,
      );

      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => BackgroundStreamingHandler.instance.keepAlive(),
      );

      _socketSubscription = _socketService.addChatEventHandler(
        conversationId: conversationId,
        sessionId: _sessionId,
        requireFocus: false,
        handler: _handleSocketEvent,
      );

      await _beginListening();
    } catch (e) {
      await _cleanupCall();
      _updateState(VoiceCallState.error);
      rethrow;
    }
  }

  Future<void> stopCall() async {
    if (_isDisposed) return;
    await _cleanupCall();
    _updateState(VoiceCallState.disconnected);
  }

  Future<void> _cleanupCall() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    await _stopListening();
    _socketSubscription?.dispose();
    _socketSubscription = null;

    await _tts.stop();
    
    await BackgroundStreamingHandler.instance.stopBackgroundExecution(
      const [_voiceCallStreamId],
    );
    await _notificationService.cancelNotification();
    await WakelockPlus.disable();

    _sessionId = null;
    _currentTranscript = '';
    _streamingResponse = '';
    _responseComplete = false;
    _sentencesToSpeak.clear();
    _sentencesProcessed = 0;
    _isSpeaking = false;
    _isBackgroundStreaming = false;
    _manualSendPending = false;
    _pauseReasons.clear();
  }

  // ============================================================================
  // Listening phase
  // ============================================================================

  Future<void> _beginListening() async {
    if (_isDisposed) return;
    
    // Check if paused
    if (_pauseReasons.isNotEmpty) {
      _updateState(VoiceCallState.paused);
      return;
    }

    // Verify STT is available
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
      throw Exception('Speech recognition engine is unavailable');
    }

    // Only clear transcript if NOT in background streaming mode
    if (!_isBackgroundStreaming) {
      _currentTranscript = '';
    }
    
    _updateState(VoiceCallState.listening);

    try {
      final stream = await _voiceInput.beginListening();
      
      _transcriptSubscription = stream.listen(
        (text) {
          if (_isDisposed || _state != VoiceCallState.listening) return;
          _currentTranscript = text;
          _transcriptController.add(text);
        },
        onError: (error) {
          if (_isDisposed) return;
          _updateState(VoiceCallState.error);
        },
        onDone: () {
          // Only process if still in listening state
          if (_isDisposed || _state != VoiceCallState.listening) return;
          _onVoiceInputComplete();
        },
      );

      _intensitySubscription = _voiceInput.intensityStream.listen((intensity) {
        if (_isDisposed || _state != VoiceCallState.listening) return;
        _intensityController.add(intensity);
      });
    } catch (e) {
      _updateState(VoiceCallState.error);
      rethrow;
    }
  }

  Future<void> _stopListening() async {
    await _transcriptSubscription?.cancel();
    _transcriptSubscription = null;
    await _intensitySubscription?.cancel();
    _intensitySubscription = null;
    await _voiceInput.stopListening();
  }

  void _onVoiceInputComplete() {
    // User stopped speaking (VAD detected end) OR manual send triggered completion
    
    // Check if this was a manual send
    final wasManualSend = _manualSendPending;
    _manualSendPending = false;
    
    // Get the transcript (server STT sends it in onDone)
    final transcript = _currentTranscript.trim();
    
    // Manual send ALWAYS sends (even if empty - though we could check)
    if (wasManualSend) {
      if (transcript.isEmpty) {
        // Manual send but no transcript, just restart listening
        _beginListening();
        return;
      }
      _sendUserMessage(transcript);
      return;
    }
    
    // CRITICAL: If in background streaming mode, do NOT auto-send
    // User must manually send to interrupt the LLM
    // This prevents ambient noise from accidentally interrupting
    if (_isBackgroundStreaming) {
      // Just restart listening to continue accumulating transcript
      _beginListening();
      return;
    }
    
    // Normal flow: auto-send when VAD completes
    if (transcript.isNotEmpty) {
      _sendUserMessage(transcript);
    } else {
      // No input, restart listening
      _beginListening();
    }
  }

  Future<void> manualSend() async {
    if (_state != VoiceCallState.listening) return;

    // Set flag so onDone knows this was a manual send (not auto-VAD)
    _manualSendPending = true;
    
    // Reset VAD pause if active
    if (_vadPaused) {
      _vadPaused = false;
      _vadPausedController.add(false);
    }
    
    // If interrupting background stream, exit that mode
    _isBackgroundStreaming = false;
    
    // Force VAD to complete by stopping the voice input
    // This will trigger onDone callback with the transcript
    await _voiceInput.stopListening();
    
    // Note: onDone will handle actually sending the message
  }

  // ============================================================================
  // Processing phase
  // ============================================================================

  void _sendUserMessage(String text) {
    if (_isDisposed) return;

    // Increment generation to ignore the OLD streaming response
    // The old response stays in chat history, but new streaming won't mix with it
    _messageGeneration++;
    
    // Clear state for new response
    _currentTranscript = '';
    _streamingResponse = '';
    _responseComplete = false;
    _sentencesToSpeak.clear();
    _sentencesProcessed = 0;
    _isBackgroundStreaming = false;
    
    _updateState(VoiceCallState.processing);
    
    // Send to chat service
    sendMessageFromService(_ref, text, null);
  }

  void _handleSocketEvent(
    Map<String, dynamic> event,
    void Function(dynamic response)? ack,
  ) {
    if (_isDisposed) return;

    // Capture generation at start to filter stale responses
    final currentGeneration = _messageGeneration;

    final outerData = event['data'];
    if (outerData is! Map<String, dynamic>) return;

    final eventType = outerData['type']?.toString();
    final innerData = outerData['data'];

    if (eventType != 'chat:completion' || innerData is! Map<String, dynamic>) {
      return;
    }

    // Ignore stale responses from previous messages
    if (currentGeneration != _messageGeneration) return;

    // Handle full content replacement
    if (innerData.containsKey('content')) {
      final content = innerData['content']?.toString() ?? '';
      if (content.isNotEmpty && currentGeneration == _messageGeneration) {
        _streamingResponse = content;
        _responseController.add(content);
        _onResponseChunk?.call();
        _processResponseChunk();
      }
    }

    // Handle streaming delta
    if (innerData.containsKey('choices')) {
      final choices = innerData['choices'] as List?;
      if (choices == null || choices.isEmpty) return;

      final firstChoice = choices[0] as Map<String, dynamic>?;
      final delta = firstChoice?['delta'];
      final finishReason = firstChoice?['finish_reason'];

      if (delta is Map<String, dynamic>) {
        final deltaContent = delta['content']?.toString() ?? '';
        if (deltaContent.isNotEmpty && currentGeneration == _messageGeneration) {
          _streamingResponse += deltaContent;
          _responseController.add(_streamingResponse);
          _onResponseChunk?.call();
          _processResponseChunk();
        }
      }

      if (finishReason == 'stop' && currentGeneration == _messageGeneration) {
        _responseComplete = true;
        _processResponseChunk();
      }
    }
  }

  void _processResponseChunk() {
    if (_isDisposed || _streamingResponse.isEmpty) return;

    // Convert markdown to clean text
    final cleanText = MarkdownToText.convert(_streamingResponse);
    if (cleanText.isEmpty) return;

    // Split into sentences
    final allSentences = _tts.splitTextForSpeech(cleanText);
    
    // Determine new sentences to queue
    List<String> newSentences;
    if (_responseComplete) {
      // Response complete, queue all remaining sentences
      newSentences = allSentences.skip(_sentencesProcessed).toList();
    } else {
      // Response streaming, only queue complete sentences (leave last one)
      if (allSentences.length > _sentencesProcessed + 1) {
        newSentences = allSentences
            .skip(_sentencesProcessed)
            .take(allSentences.length - _sentencesProcessed - 1)
            .toList();
      } else {
        newSentences = [];
      }
    }

    // Add new sentences to queue
    for (final sentence in newSentences) {
      if (sentence.trim().isNotEmpty) {
        _sentencesToSpeak.add(sentence);
        _sentencesProcessed++;
      }
    }

    // If in background streaming mode, don't speak
    // Just stay listening, response accumulates in background
    if (_isBackgroundStreaming) {
      // Response streams silently while user prepares their response
      return;
    }
    
    // Normal flow: start speaking if not already
    if (!_isSpeaking && _sentencesToSpeak.isNotEmpty) {
      _speakNextSentence();
    } else if (_responseComplete && _sentencesToSpeak.isEmpty && !_isSpeaking) {
      // Response complete with nothing to speak, return to listening
      _beginListening();
    }
  }

  // ============================================================================
  // Speaking phase
  // ============================================================================

  Future<void> _speakNextSentence() async {
    if (_isDisposed || _isSpeaking || _sentencesToSpeak.isEmpty) return;

    _isSpeaking = true;
    _pauseReasons.add(VoiceCallPauseReason.system);
    
    // Ensure listening is fully stopped
    await _stopListening();
    
    _updateState(VoiceCallState.speaking);

    final sentence = _sentencesToSpeak.removeAt(0);

    try {
      await _tts.speak(sentence);
    } catch (e) {
      _isSpeaking = false;
      _pauseReasons.remove(VoiceCallPauseReason.system);
      _updateState(VoiceCallState.error);
    }
  }

  void _onTtsStart() {
    if (_isDisposed) return;
    _updateState(VoiceCallState.speaking);
  }

  void _onTtsComplete() {
    if (_isDisposed) return;
    
    _isSpeaking = false;
    _pauseReasons.remove(VoiceCallPauseReason.system);

    // Continue speaking if more sentences queued
    if (_sentencesToSpeak.isNotEmpty) {
      _speakNextSentence();
      return;
    }

    // No more queued sentences
    if (_responseComplete) {
      // Response fully delivered, return to listening
      if (_pauseReasons.isEmpty) {
        _beginListening();
      } else {
        _updateState(VoiceCallState.paused);
      }
    } else {
      // Response still streaming, wait for more
      // This shouldn't normally happen (we should have more sentences or be complete)
      // But if it does, stay in processing
      if (!_isBackgroundStreaming) {
        _updateState(VoiceCallState.processing);
      }
    }
  }

  void _onTtsError(String error) {
    if (_isDisposed) return;
    
    _isSpeaking = false;
    _pauseReasons.remove(VoiceCallPauseReason.system);
    _updateState(VoiceCallState.error);
  }

  Future<void> muteSpeaking() async {
    if (_isDisposed) return;

    // Stop TTS audio but preserve response data
    await _tts.stop();
    _isSpeaking = false;
    _sentencesToSpeak.clear();
    _pauseReasons.remove(VoiceCallPauseReason.system);

    // Enable background streaming mode if response not complete
    // This allows LLM to continue streaming while user prepares response
    if (!_responseComplete) {
      _isBackgroundStreaming = true;
    }
    
    // ALWAYS return to listening when muted (unless other pause reasons)
    // This allows user to prepare interrupt while LLM streams in background
    if (_pauseReasons.isEmpty) {
      await _beginListening();
    } else {
      _updateState(VoiceCallState.paused);
    }
  }

  // ============================================================================
  // Pause/Resume
  // ============================================================================

  Future<void> pauseListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) async {
    if (_isDisposed) return;

    final wasEmpty = _pauseReasons.isEmpty;
    _pauseReasons.add(reason);

    if (!wasEmpty) return;

    await _stopListening();

    if (_state == VoiceCallState.listening) {
      _updateState(VoiceCallState.paused);
    }
  }

  Future<void> resumeListening({
    VoiceCallPauseReason reason = VoiceCallPauseReason.user,
  }) async {
    if (_isDisposed) return;

    _pauseReasons.remove(reason);

    if (_pauseReasons.isNotEmpty) return;

    if (_state == VoiceCallState.paused) {
      await _beginListening();
    }
  }

  // ============================================================================
  // VAD pause
  // ============================================================================

  void pauseVad() {
    if (!_voiceInput.usingServerStt || _state != VoiceCallState.listening) {
      return;
    }
    _vadPaused = true;
    _vadPausedController.add(true);
    _voiceInput.pauseVad();
  }

  void resumeVad() {
    if (!_vadPaused) return;
    _vadPaused = false;
    _vadPausedController.add(false);
    _voiceInput.resumeVad();
  }

  // ============================================================================
  // Notification
  // ============================================================================

  void _updateState(VoiceCallState newState) {
    if (_isDisposed) return;
    _state = newState;
    _stateController.add(newState);
    _updateNotification();
  }

  Future<void> _updateNotification() async {
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
        isMuted: _pauseReasons.contains(VoiceCallPauseReason.mute),
        isSpeaking: _state == VoiceCallState.speaking,
        isPaused: _state == VoiceCallState.paused,
      );
    } catch (e) {
      // Ignore notification errors
    }
  }

  void _handleNotificationAction(String action) {
    switch (action) {
      case 'mute_call':
      case 'unmute_call':
        _toggleMute();
        break;
      case 'end_call':
        stopCall();
        break;
    }
  }

  void _toggleMute() {
    final isMuted = _pauseReasons.contains(VoiceCallPauseReason.mute);
    if (isMuted) {
      resumeListening(reason: VoiceCallPauseReason.mute);
    } else {
      if (_isSpeaking) {
        muteSpeaking();
      }
      pauseListening(reason: VoiceCallPauseReason.mute);
    }
  }

  // ============================================================================
  // Disposal
  // ============================================================================

  Future<void> dispose() async {
    _isDisposed = true;
    await _cleanupCall();
    _voiceInput.dispose();
    await _tts.dispose();
    await _stateController.close();
    await _transcriptController.close();
    await _responseController.close();
    await _intensityController.close();
    await _vadPausedController.close();
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

  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
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