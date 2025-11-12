import 'dart:async';
import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../../core/services/api_service.dart';
import '../../../core/services/settings_service.dart';

typedef _SpeechChunk = ({Uint8List bytes, String mimeType});

class SpeechAudioChunk {
  const SpeechAudioChunk({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

/// Lightweight wrapper around FlutterTts to centralize configuration
class TextToSpeechService {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  final ApiService? _api;
  TtsEngine _engine = TtsEngine.auto;
  String? _preferredVoice;
  String? _serverPreferredVoice;
  double _speechRate = 0.5;
  bool _initialized = false;
  bool _available = false;
  bool _voiceConfigured = false;
  int _session = 0; // increments to cancel in-flight work
  final List<_SpeechChunk> _buffered = <_SpeechChunk>[]; // server chunks
  int _expectedChunks = 0;
  int _currentIndex = -1;
  bool _waitingNext = false;
  bool _deviceEngineAvailable = false;
  String? _serverDefaultVoice;
  Future<String?>? _serverDefaultVoiceFuture;

  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;
  void Function(int sentenceIndex)? _onSentenceIndex;
  void Function(int start, int end)? _onDeviceWordProgress;

  bool get isInitialized => _initialized;
  bool get isAvailable => _available;
  bool get deviceEngineAvailable => _deviceEngineAvailable;
  bool get serverEngineAvailable => _api != null;
  bool get prefersServerEngine => _shouldUseServer();

  TextToSpeechService({ApiService? api}) : _api = api {
    // Wire minimal player events to callbacks
    _player.onPlayerComplete.listen((_) => _onAudioComplete());
    _player.onPlayerStateChanged.listen((state) {
      switch (state) {
        case PlayerState.playing:
          _handleStart();
          break;
        case PlayerState.paused:
          _handlePause();
          break;
        default:
          break;
      }
    });
  }

  Future<void> _configureDeviceEngine({
    required String? voice,
    required double speechRate,
    required double pitch,
    required double volume,
  }) async {
    _deviceEngineAvailable = false;
    try {
      await _tts.awaitSpeakCompletion(false);
      await _tts.setVolume(volume);
      await _tts.setSpeechRate(speechRate);
      await _tts.setPitch(pitch);

      if (!kIsWeb && Platform.isIOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ]);
      }

      if (_engine != TtsEngine.server) {
        await _setVoiceByName(_preferredVoice);
      } else {
        _voiceConfigured = false;
      }

      _deviceEngineAvailable = true;
    } catch (e) {
      _voiceConfigured = false;
      _deviceEngineAvailable = false;
      rethrow;
    }
  }

  bool _computeAvailability() {
    final serverAvailable = _api != null;
    switch (_engine) {
      case TtsEngine.device:
        return _deviceEngineAvailable;
      case TtsEngine.server:
        return serverAvailable;
      case TtsEngine.auto:
        return _deviceEngineAvailable || serverAvailable;
    }
  }

  bool _shouldUseServer() {
    if (_engine == TtsEngine.server) {
      return _api != null;
    }
    if (_engine == TtsEngine.device) {
      return false;
    }
    // Auto: prefer device when available, otherwise fall back to server
    if (_deviceEngineAvailable) {
      return false;
    }
    return _api != null;
  }

  /// Register callbacks for TTS lifecycle events
  void bindHandlers({
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onCancel,
    VoidCallback? onPause,
    VoidCallback? onContinue,
    void Function(String message)? onError,
    void Function(int sentenceIndex)? onSentenceIndex,
    void Function(int start, int end)? onDeviceWordProgress,
  }) {
    _onStart = onStart;
    _onComplete = onComplete;
    _onCancel = onCancel;
    _onPause = onPause;
    _onContinue = onContinue;
    _onError = onError;
    _onSentenceIndex = onSentenceIndex;
    _onDeviceWordProgress = onDeviceWordProgress;

    _tts.setStartHandler(_handleStart);
    _tts.setCompletionHandler(_handleComplete);
    _tts.setCancelHandler(_handleCancel);
    _tts.setPauseHandler(_handlePause);
    _tts.setContinueHandler(_handleContinue);
    _tts.setErrorHandler(_handleError);
    try {
      _tts.setProgressHandler((String text, int start, int end, String word) {
        _onDeviceWordProgress?.call(start, end);
      });
    } catch (_) {
      // Some platforms may not support progress handler
    }
  }

  /// Initialize the native TTS engine lazily
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.auto,
  }) async {
    if (_initialized) {
      _engine = engine;
      _speechRate = speechRate;
      if (deviceVoice != null) {
        _preferredVoice = deviceVoice;
        _voiceConfigured = false;
      }
      if (serverVoice != null) {
        _serverPreferredVoice = serverVoice;
      }
      _available = _computeAvailability();
      return _available;
    }

    _engine = engine;
    _speechRate = speechRate;
    _preferredVoice = deviceVoice;
    _serverPreferredVoice = serverVoice;
    _voiceConfigured = false;

    if (_engine != TtsEngine.server || _api == null) {
      try {
        await _configureDeviceEngine(
          voice: deviceVoice,
          speechRate: speechRate,
          pitch: pitch,
          volume: volume,
        );
      } catch (e) {
        if (_engine == TtsEngine.device) {
          _available = false;
          _onError?.call(e.toString());
          _initialized = true;
          return _available;
        }
      }
    } else {
      _deviceEngineAvailable = false;
      try {
        await _tts.awaitSpeakCompletion(false);
        await _tts.setVolume(volume);
        await _tts.setSpeechRate(speechRate);
        await _tts.setPitch(pitch);
      } catch (_) {}
    }

    _available = _computeAvailability();
    _initialized = true;
    return _available;
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot speak empty text');
    }

    if (!_initialized) {
      await initialize(
        deviceVoice: _preferredVoice,
        serverVoice: _serverPreferredVoice,
        engine: _engine,
      );
    }

    final bool useServer = _shouldUseServer();

    if (useServer) {
      if (_api == null) {
        if (_deviceEngineAvailable) {
          await _speakOnDevice(text);
          return;
        }
        throw StateError('Server text-to-speech is unavailable');
      }
      // Server-backed TTS with sentence chunking & queued playback
      try {
        await _startServerChunkedPlayback(text);
      } catch (e) {
        _onError?.call(e.toString());
        if (_deviceEngineAvailable) {
          await _speakOnDevice(text);
        } else {
          throw StateError('Server text-to-speech failed: $e');
        }
      }
      return;
    }

    // Device TTS path
    await _speakOnDevice(text);
  }

  Future<void> _speakOnDevice(String text) async {
    if (!_deviceEngineAvailable) {
      throw StateError('Device text-to-speech is unavailable');
    }
    await _tts.stop();
    if (!_voiceConfigured) {
      await _configurePreferredVoice();
    }
    final result = await _tts.speak(text);
    if (result is int && result != 1) {
      _onError?.call('Text-to-speech engine returned code $result');
    }
    _onSentenceIndex?.call(0);
  }

  Future<SpeechAudioChunk> synthesizeServerSpeechChunk(String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot synthesize empty text');
    }
    if (_api == null) {
      throw StateError('Server text-to-speech is unavailable');
    }
    if (!_initialized) {
      await initialize(
        deviceVoice: _preferredVoice,
        serverVoice: _serverPreferredVoice,
        engine: _engine,
      );
    }
    final voice = await _resolveServerVoice();
    final chunk = await _api.generateSpeech(
      text: text,
      voice: voice,
      speed: _speechRate,
    );
    return SpeechAudioChunk(bytes: chunk.bytes, mimeType: chunk.mimeType);
  }

  Future<void> pause() async {
    if (!_initialized) return;
    try {
      if (_shouldUseServer()) {
        await _player.pause();
        _handlePause();
      } else if (_deviceEngineAvailable) {
        await _tts.pause();
      }
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  Future<void> resume() async {
    if (!_initialized) return;
    try {
      if (_shouldUseServer()) {
        if (_waitingNext && (_currentIndex + 1) < _buffered.length) {
          _waitingNext = false;
          await _playNextIfBuffered(_session);
        } else {
          await _player.resume();
        }
      }
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  Future<void> stop() async {
    if (!_initialized) {
      return;
    }

    try {
      // Cancel any in-flight server work
      _session++;
      _buffered.clear();
      _expectedChunks = 0;
      _currentIndex = -1;
      _waitingNext = false;
      if (_shouldUseServer()) {
        await _player.stop();
        _handleCancel();
      } else {
        await _tts.stop();
      }
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }

  /// Update TTS settings on-the-fly
  Future<void> updateSettings({
    Object? voice = const _VoiceNotProvided(),
    Object? serverVoice = const _VoiceNotProvided(),
    double? speechRate,
    double? pitch,
    double? volume,
    TtsEngine? engine,
  }) async {
    final voiceProvided = voice is! _VoiceNotProvided;
    final serverVoiceProvided = serverVoice is! _VoiceNotProvided;
    final voiceValue = voiceProvided ? voice as String? : null;
    final serverVoiceValue = serverVoiceProvided
        ? serverVoice as String?
        : null;
    if (!_initialized || !_available) {
      // Allow engine and voice to update before init
      if (engine != null) _engine = engine;
      if (voiceProvided) _preferredVoice = voiceValue;
      if (serverVoiceProvided) _serverPreferredVoice = serverVoiceValue;
      if (speechRate != null) _speechRate = speechRate;
      return;
    }

    try {
      if (engine != null) {
        _engine = engine;
      }
      if (voiceProvided) {
        _preferredVoice = voiceValue;
      }
      if (serverVoiceProvided) {
        _serverPreferredVoice = serverVoiceValue;
      }
      if (volume != null) {
        await _tts.setVolume(volume);
      }
      if (speechRate != null) {
        _speechRate = speechRate;
        await _tts.setSpeechRate(speechRate);
      }
      if (pitch != null) {
        await _tts.setPitch(pitch);
      }
      // Set specific voice by name on device-capable engines
      if (_engine != TtsEngine.server && voiceProvided) {
        await _setVoiceByName(_preferredVoice);
      }
    } catch (e) {
      _onError?.call(e.toString());
    }

    _available = _computeAvailability();
  }

  /// Set voice by name, or use system default if null
  Future<void> _setVoiceByName(String? voiceName) async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return;
    }

    try {
      if (voiceName == null) {
        // Use system default - reset voice configuration
        _voiceConfigured = false;
        await _configurePreferredVoice();
        return;
      }

      // Get all available voices
      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return;
      }

      // Find the voice by name
      Map<String, dynamic>? targetVoice;
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          final name = normalized['name'] as String?;
          if (name == voiceName) {
            targetVoice = normalized;
            break;
          }
        }
      }

      // Set the voice if found
      if (targetVoice != null) {
        await _tts.setVoice(_voiceCommandFrom(targetVoice));
        _voiceConfigured = true;
      } else {
        // Voice not found, fall back to default
        _voiceConfigured = false;
        await _configurePreferredVoice();
      }
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  /// Get available voices from the TTS engine
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_initialized) {
      await initialize(
        deviceVoice: _preferredVoice,
        serverVoice: _serverPreferredVoice,
        engine: _engine,
      );
    }

    if (_engine == TtsEngine.server && _api != null) {
      try {
        final serverVoices = await _api.getAvailableServerVoices();
        final mapped = serverVoices
            .map((v) {
              final id = (v['id'] ?? v['name'] ?? '').toString();
              final name = (v['name'] ?? v['id'] ?? '').toString();
              final localeValue = (v['locale'] ?? v['language'] ?? '')
                  .toString();
              return {'id': id, 'name': name, 'locale': localeValue};
            })
            .where((entry) {
              final name = entry['name'];
              return name is String && name.trim().isNotEmpty;
            })
            .toList();

        final defaultVoice = await _getServerDefaultVoice();
        if (defaultVoice != null && defaultVoice.isNotEmpty) {
          final normalized = defaultVoice.toLowerCase();
          final exists = mapped.any((voice) {
            final name = voice['name'];
            final id = voice['id'];
            final lowerName = name is String ? name.toLowerCase() : '';
            final lowerId = id is String ? id.toLowerCase() : '';
            return lowerName == normalized || lowerId == normalized;
          });
          if (!exists) {
            mapped.insert(0, {
              'id': defaultVoice,
              'name': defaultVoice,
              'locale': '',
            });
          }
        }

        if (mapped.isEmpty) {
          if (defaultVoice != null && defaultVoice.isNotEmpty) {
            return [
              {'id': defaultVoice, 'name': defaultVoice, 'locale': ''},
            ];
          }
          return const [];
        }
        return mapped;
      } catch (e) {
        _onError?.call(e.toString());
        // Fall back to device voices
      }
    }

    if (!_available) {
      return [];
    }

    try {
      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return [];
      }

      final parsedVoices = <Map<String, dynamic>>[];
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          if (normalized.isNotEmpty) {
            parsedVoices.add(normalized);
          }
        }
      }

      return parsedVoices;
    } catch (e) {
      _onError?.call(e.toString());
      return [];
    }
  }

  Future<String?> _resolveServerVoice() async {
    final serverSelected = _serverPreferredVoice?.trim();
    if (serverSelected != null && serverSelected.isNotEmpty) {
      return serverSelected;
    }
    final selected = _preferredVoice?.trim();
    if (selected != null && selected.isNotEmpty) {
      return selected;
    }
    final configVoice = await _getServerDefaultVoice();
    if (configVoice != null && configVoice.isNotEmpty) {
      return configVoice;
    }
    return null;
  }

  Future<String?> _getServerDefaultVoice() async {
    if (_api == null) {
      return null;
    }
    if (_serverDefaultVoice != null) {
      return _serverDefaultVoice;
    }
    final pending = _serverDefaultVoiceFuture;
    if (pending != null) {
      return pending;
    }

    final future = _api.getDefaultServerVoice();
    _serverDefaultVoiceFuture = future;

    try {
      final voice = await future;
      final trimmed = voice?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        _serverDefaultVoice = trimmed;
        return _serverDefaultVoice;
      }
      return null;
    } catch (e) {
      _onError?.call(e.toString());
      return null;
    } finally {
      _serverDefaultVoiceFuture = null;
    }
  }

  Future<void> preloadServerDefaults() async {
    if (_api == null) {
      return;
    }
    try {
      await _getServerDefaultVoice();
    } catch (_) {}
  }

  // ===== Server chunked playback =====

  Future<void> _startServerChunkedPlayback(String text) async {
    final resolvedVoice = await _resolveServerVoice();
    final effectiveVoice = resolvedVoice;

    // Reset queue and create a new session
    _session++;
    final session = _session;
    _buffered.clear();
    _expectedChunks = 0;
    _currentIndex = -1;
    _waitingNext = false;

    final chunks = _splitForTts(text);
    if (chunks.isEmpty) return;
    _expectedChunks = chunks.length;

    // Fetch first chunk to start playback quickly
    final firstChunk = await _fetchServerAudio(
      chunks.first,
      effectiveVoice,
      session,
    );
    if (session != _session) return; // canceled
    if (firstChunk.bytes.isEmpty) {
      throw Exception('Empty audio response');
    }

    await _player.stop();
    final bufferedFirst = _cloneChunk(firstChunk);
    _buffered.add(bufferedFirst);
    _currentIndex = 0;
    await _player.play(
      BytesSource(bufferedFirst.bytes, mimeType: bufferedFirst.mimeType),
    );
    _onSentenceIndex?.call(0);

    // Prefetch the rest in background
    unawaited(
      _prefetchRemainingChunks(
        chunks.skip(1).toList(),
        effectiveVoice,
        session,
      ),
    );
  }

  Future<void> _prefetchRemainingChunks(
    List<String> remaining,
    String? voice,
    int session,
  ) async {
    for (final chunk in remaining) {
      if (session != _session) return; // canceled
      try {
        final audioChunk = await _fetchServerAudio(chunk, voice, session);
        if (session != _session) return;
        if (audioChunk.bytes.isNotEmpty) {
          _buffered.add(_cloneChunk(audioChunk));
          // If the player finished the previous chunk and is waiting, start now
          if (_waitingNext && (_currentIndex + 1) < _buffered.length) {
            _waitingNext = false;
            await _playNextIfBuffered(session);
          }
        }
      } catch (e) {
        _onError?.call(e.toString());
        // continue with other chunks
      }
    }
  }

  Future<_SpeechChunk> _fetchServerAudio(
    String text,
    String? voice,
    int session,
  ) async {
    return await _api!.generateSpeech(
      text: text,
      voice: voice,
      speed: _speechRate,
    );
  }

  /// Splits [text] into the chunks used for playback sequencing.
  ///
  /// This mirrors the server-side streaming behavior so UI consumers can stay
  /// in sync with sentence indices reported during playback.
  List<String> splitTextForSpeech(String text) => _splitForTts(text);

  Future<void> _onAudioComplete() async {
    final session = _session;
    // If there are more expected chunks
    if ((_currentIndex + 1) < _expectedChunks) {
      // If next chunk is already buffered, play it
      if ((_currentIndex + 1) < _buffered.length) {
        await _playNextIfBuffered(session);
      } else {
        // Wait for prefetch to provide it
        _waitingNext = true;
      }
      return;
    }
    // No more chunks – this is the real completion
    _handleComplete();
  }

  Future<void> _playNextIfBuffered(int session) async {
    if (session != _session) return;
    final nextIndex = _currentIndex + 1;
    if (nextIndex < 0 || nextIndex >= _buffered.length) return;
    _currentIndex = nextIndex;
    final chunk = _buffered[nextIndex];
    await _player.play(BytesSource(chunk.bytes, mimeType: chunk.mimeType));
    _onSentenceIndex?.call(_currentIndex);
  }

  _SpeechChunk _cloneChunk(_SpeechChunk chunk) {
    return (bytes: Uint8List.fromList(chunk.bytes), mimeType: chunk.mimeType);
  }

  List<String> _splitForTts(String text) {
    // Mirrors OpenWebUI's extractSentencesForAudio implementation
    // See: src/lib/utils/index.ts lines 953-970, 907-928

    // 1. Preserve code blocks (replace with placeholders)
    final codeBlocks = <String>[];
    var processed = text;
    var codeBlockIndex = 0;

    // Match triple backticks code blocks
    final codeBlockRegex = RegExp(r'```[\s\S]*?```', multiLine: true);
    processed = processed.replaceAllMapped(codeBlockRegex, (match) {
      final placeholder = '\u0000$codeBlockIndex\u0000';
      codeBlocks.add(match.group(0)!);
      codeBlockIndex++;
      return placeholder;
    });

    // 2. Split on sentence-ending punctuation: .!?
    // OpenWebUI uses: /(?<=[.!?])\s+/
    final sentences = processed
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    // 3. Restore code blocks from placeholders
    final restoredSentences = sentences
        .map((sentence) {
          return sentence.replaceAllMapped(RegExp(r'\u0000(\d+)\u0000'), (
            match,
          ) {
            final idx = int.parse(match.group(1)!);
            return idx < codeBlocks.length ? codeBlocks[idx] : '';
          });
        })
        .where((s) => s.isNotEmpty)
        .toList();

    // 4. Merge short sentences (< 4 words OR < 50 chars)
    // OpenWebUI logic from extractSentencesForAudio
    final mergedChunks = <String>[];
    for (final sentence in restoredSentences) {
      if (mergedChunks.isEmpty) {
        mergedChunks.add(sentence);
      } else {
        final lastIndex = mergedChunks.length - 1;
        final previousText = mergedChunks[lastIndex];
        final wordCount = previousText.split(RegExp(r'\s+')).length;
        final charCount = previousText.length;

        // Merge if previous chunk is too short
        if (wordCount < 4 || charCount < 50) {
          mergedChunks[lastIndex] = '$previousText $sentence';
        } else {
          mergedChunks.add(sentence);
        }
      }
    }

    return mergedChunks.isEmpty ? [text.trim()] : mergedChunks;
  }

  Future<void> _configurePreferredVoice() async {
    if (_voiceConfigured) {
      return;
    }
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      _voiceConfigured = true;
      return;
    }

    var configured = false;
    try {
      Map<String, dynamic>? defaultVoice;
      bool voiceSet = false;

      if (Platform.isIOS) {
        try {
          final rawDefault = await _tts.getDefaultVoice;
          if (rawDefault is Map) {
            defaultVoice = _normalizeVoiceEntry(rawDefault);
            await _tts.setVoice(_voiceCommandFrom(defaultVoice));
            configured = true;
            voiceSet = true;
          }
        } catch (_) {
          defaultVoice = null;
        }
      }

      if (voiceSet) {
        return;
      }

      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return;
      }

      final parsedVoices = <Map<String, dynamic>>[];
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          if (normalized.isNotEmpty) {
            parsedVoices.add(normalized);
          }
        }
      }

      if (parsedVoices.isEmpty) {
        return;
      }

      final localeTag = WidgetsBinding.instance.platformDispatcher.locale
          .toLanguageTag()
          .toLowerCase();
      final preferred = _selectPreferredVoice(
        parsedVoices,
        localeTag,
        defaultVoice: defaultVoice,
      );
      if (preferred == null) {
        if (Platform.isIOS) {
          configured = true; // Allow system default voice to be used
        }
        return;
      }

      await _tts.setVoice(_voiceCommandFrom(preferred));
      configured = true;
    } catch (e) {
      _onError?.call(e.toString());
    } finally {
      _voiceConfigured = configured || _voiceConfigured;
    }
  }

  Map<String, dynamic> _normalizeVoiceEntry(Map<dynamic, dynamic> entry) {
    final normalized = <String, dynamic>{};
    entry.forEach((key, value) {
      if (key != null) {
        normalized[key.toString()] = value;
      }
    });
    return normalized;
  }

  Map<String, String> _voiceCommandFrom(Map<String, dynamic> voice) {
    final command = <String, String>{};
    for (final key in [
      'name',
      'locale',
      'identifier',
      'id',
      'voiceIdentifier',
      'engine',
    ]) {
      final value = voice[key];
      if (value != null) {
        command[key] = value.toString();
      }
    }
    if (!command.containsKey('name') && voice['name'] != null) {
      command['name'] = voice['name'].toString();
    }
    if (!command.containsKey('locale') && voice['locale'] != null) {
      command['locale'] = voice['locale'].toString();
    }
    return command;
  }

  int _iosVoiceScore(Map<String, dynamic> voice) {
    final identifier =
        voice['identifier']?.toString().toLowerCase() ??
        voice['id']?.toString().toLowerCase() ??
        '';
    final name = voice['name']?.toString().toLowerCase() ?? '';

    int score = 0;
    if (identifier.contains('premium')) {
      score += 400;
    } else if (identifier.contains('enhanced')) {
      score += 250;
    } else if (identifier.contains('compact')) {
      score += 50;
    }

    if (identifier.contains('siri') || name.contains('siri')) {
      score += 150;
    }

    if (identifier.contains('female') || name.contains('female')) {
      score += 15;
    }
    if (identifier.contains('male') || name.contains('male')) {
      score += 10;
    }

    // Prefer non-compact by default when no other hints are present
    if (!identifier.contains('compact')) {
      score += 25;
    }

    return score;
  }

  Map<String, dynamic>? _selectPreferredVoice(
    List<Map<String, dynamic>> voices,
    String localeTag, {
    Map<String, dynamic>? defaultVoice,
  }) {
    Map<String, dynamic>? matchesLocale(Iterable<Map<String, dynamic>> input) {
      for (final voice in input) {
        final locale = voice['locale']?.toString().toLowerCase();
        if (locale == null) continue;
        if (locale == localeTag) {
          return voice;
        }
        final localePrimary = locale.split(RegExp('[-_]')).first;
        final tagPrimary = localeTag.split(RegExp('[-_]')).first;
        if (localePrimary == tagPrimary) {
          return voice;
        }
      }
      return null;
    }

    Map<String, dynamic>? matchDefaultVoice() {
      final dv = defaultVoice;
      if (dv == null) {
        return null;
      }

      final identifiers = <String>{};
      for (final key in ['identifier', 'id', 'voiceIdentifier', 'voice']) {
        final value = dv[key]?.toString();
        if (value != null && value.isNotEmpty) {
          identifiers.add(value.toLowerCase());
        }
      }

      if (identifiers.isNotEmpty) {
        for (final voice in voices) {
          for (final key in ['identifier', 'id', 'voiceIdentifier', 'voice']) {
            final value = voice[key]?.toString();
            if (value != null && identifiers.contains(value.toLowerCase())) {
              return voice;
            }
          }
        }
      }

      final defaultName = dv['name']?.toString();
      final defaultLocale = dv['locale']?.toString();
      if (defaultName != null && defaultLocale != null) {
        final lowerName = defaultName.toLowerCase();
        final lowerLocale = defaultLocale.toLowerCase();
        for (final voice in voices) {
          final name = voice['name']?.toString();
          final locale = voice['locale']?.toString();
          if (name != null &&
              locale != null &&
              name.toLowerCase() == lowerName &&
              locale.toLowerCase() == lowerLocale) {
            return voice;
          }
        }
      }

      return null;
    }

    Map<String, dynamic>? pickIosVoice() {
      final userDefault = matchDefaultVoice();
      if (userDefault != null) {
        return userDefault;
      }

      final siriCandidates = voices.where((voice) {
        final name = voice['name']?.toString().toLowerCase() ?? '';
        final identifier = voice['identifier']?.toString().toLowerCase() ?? '';
        final voiceId = voice['id']?.toString().toLowerCase() ?? '';
        return name.contains('siri') ||
            identifier.contains('siri') ||
            voiceId.contains('siri');
      }).toList();

      if (siriCandidates.isNotEmpty) {
        siriCandidates.sort((a, b) => _iosVoiceScore(b) - _iosVoiceScore(a));
        final localeMatch = matchesLocale(siriCandidates);
        if (localeMatch != null) {
          return localeMatch;
        }
        return siriCandidates.first;
      }

      final ranked = [...voices];
      ranked.sort((a, b) => _iosVoiceScore(b) - _iosVoiceScore(a));
      final localeMatch = matchesLocale(ranked);
      if (localeMatch != null) {
        return localeMatch;
      }
      return ranked.isNotEmpty ? ranked.first : null;
    }

    Map<String, dynamic>? pickAndroidVoice() {
      int qualityScore(String? quality) {
        switch ((quality ?? '').toLowerCase()) {
          case 'very_high':
          case 'very-high':
            return 3;
          case 'high':
            return 2;
          case 'normal':
            return 1;
          default:
            return 0;
        }
      }

      final preferredEngineVoices = voices
          .where(
            (voice) =>
                (voice['engine']?.toString() ?? '').toLowerCase().contains(
                  'google',
                ) ||
                voice['engine'] is! String,
          )
          .toList();

      preferredEngineVoices.sort((a, b) {
        final qualityDiff =
            qualityScore(b['quality']?.toString()) -
            qualityScore(a['quality']?.toString());
        if (qualityDiff != 0) {
          return qualityDiff;
        }
        final latencyA = a['latency']?.toString() ?? '';
        final latencyB = b['latency']?.toString() ?? '';
        return latencyA.compareTo(latencyB);
      });

      final ordered = preferredEngineVoices.isEmpty
          ? voices
          : preferredEngineVoices;
      return matchesLocale(ordered) ?? matchesLocale(voices);
    }

    Map<String, dynamic>? selected;
    if (Platform.isIOS) {
      selected = pickIosVoice();
    } else if (Platform.isAndroid) {
      selected = pickAndroidVoice();
    }

    if (selected == null) {
      return null;
    }

    final name = selected['name']?.toString();
    final locale = selected['locale']?.toString();
    if (name == null || locale == null) {
      return null;
    }

    return selected;
  }

  void _handleStart() {
    _onStart?.call();
  }

  void _handleComplete() {
    _onComplete?.call();
  }

  void _handleCancel() {
    _onCancel?.call();
  }

  void _handlePause() {
    _onPause?.call();
  }

  void _handleContinue() {
    _onContinue?.call();
  }

  void _handleError(dynamic message) {
    final safeMessage = message == null
        ? 'Unknown TTS error'
        : message.toString();
    _onError?.call(safeMessage);
  }
}

class _VoiceNotProvided {
  const _VoiceNotProvided();
}
