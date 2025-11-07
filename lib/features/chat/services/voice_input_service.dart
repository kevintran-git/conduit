import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:mic_stream_recorder/mic_stream_recorder.dart';
import 'package:stts/stts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/api_service.dart';
import '../../../core/services/settings_service.dart';

part 'voice_input_service.g.dart';

// Lightweight replacement for previous stt.LocaleName used across the UI
class LocaleName {
  final String localeId;
  final String name;
  const LocaleName(this.localeId, this.name);
}

class VoiceInputService {
  final MicStreamRecorder _recorder = MicStreamRecorder();
  final Stt _speech = Stt();
  final ApiService? _api;
  final Ref? _ref;
  bool _isInitialized = false;
  bool _isListening = false;
  bool _localSttAvailable = false;
  SttPreference _preference = SttPreference.auto;
  bool _usingServerStt = false;
  String? _selectedLocaleId;
  List<LocaleName> _locales = const [];
  StreamController<String>? _textStreamController;
  String _currentText = '';
  StreamController<int>? _intensityController;
  Stream<int> get intensityStream =>
      _intensityController?.stream ?? const Stream<int>.empty();
  int _lastIntensity = 0;
  Timer? _intensityDecayTimer;
  Timer? _silenceTimer;
  bool _hasDetectedSpeech = false;
  int _amplitudeCallbackCount = 0;
  Timer? _amplitudeFallbackTimer;
  bool _vadPaused = false; // Track if VAD is temporarily paused

  Stream<String> get textStream =>
      _textStreamController?.stream ?? const Stream<String>.empty();
  Timer? _autoStopTimer;
  StreamSubscription<double>? _ampSub;
  StreamSubscription<SttRecognition>? _sttResultSub;
  StreamSubscription<SttState>? _sttStateSub;

  bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;
  bool get hasServerStt => _api != null;
  bool get usingServerStt => _usingServerStt;
  SttPreference get preference => _preference;
  bool get allowsServerFallback => _preference != SttPreference.deviceOnly;
  bool get prefersServerOnly => _preference == SttPreference.serverOnly;
  bool get prefersDeviceOnly => _preference == SttPreference.deviceOnly;

  VoiceInputService({ApiService? api, Ref? ref})
      : _api = api,
        _ref = ref;

  void updatePreference(SttPreference preference) {
    _preference = preference;
  }

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    if (!isSupportedPlatform) return false;
    // Prepare local speech recognizer
    try {
      // Check permission and supported status
      _localSttAvailable = await _speech.isSupported();
      if (_localSttAvailable) {
        try {
          final langs = await _speech.getLanguages();
          _locales = langs.map((l) => LocaleName(l, l)).toList();
          final deviceTag = WidgetsBinding.instance.platformDispatcher.locale
              .toLanguageTag();
          final match = _locales.firstWhere(
            (l) => l.localeId.toLowerCase() == deviceTag.toLowerCase(),
            orElse: () {
              final primary = deviceTag
                  .split(RegExp('[-_]'))
                  .first
                  .toLowerCase();
              return _locales.firstWhere(
                (l) => l.localeId.toLowerCase().startsWith('$primary-'),
                orElse: () => _locales.isNotEmpty
                    ? _locales.first
                    : LocaleName('en_US', 'en_US'),
              );
            },
          );
          _selectedLocaleId = match.localeId;
        } catch (e) {
          // ignore locale load errors
          _selectedLocaleId = null;
        }
      }
    } catch (_) {
      _localSttAvailable = false;
    }
    _isInitialized = true;
    return true;
  }

  Future<bool> checkPermissions() async {
    try {
      return await _speech.hasPermission();
    } catch (_) {
      return false;
    }
  }

  bool get isListening => _isListening;
  bool get isAvailable =>
      _isInitialized && (_localSttAvailable || hasServerStt);
  bool get hasLocalStt => _localSttAvailable;
  bool get isVadPaused => _vadPaused;

  // Add a method to check if on-device STT is properly supported
  Future<bool> checkOnDeviceSupport() async {
    if (!isSupportedPlatform || !_isInitialized) return false;
    try {
      final supported = await _speech.isSupported();
      return supported;
    } catch (e) {
      // ignore errors checking on-device support
      return false;
    }
  }

  // Test method to verify on-device STT functionality
  Future<String> testOnDeviceStt() async {
    try {
      // starting on-device STT test

      // First ensure we're initialized
      await initialize();

      if (!_localSttAvailable) {
        return 'Local STT not available. Available: $_localSttAvailable';
      }

      // Check microphone permission
      final hasMic = await checkPermissions();
      if (!hasMic) {
        return 'Microphone permission not granted';
      }

      // Test if speech recognition is available
      final supported = await _speech.isSupported();
      if (!supported) {
        return 'Speech recognition service is not available on this device';
      }

      // Set language if available, then start and stop quickly
      if (_selectedLocaleId != null) {
        try {
          await _speech.setLanguage(_selectedLocaleId!);
        } catch (_) {}
      }
      await _speech.start(SttRecognitionOptions(punctuation: true));
      await Future.delayed(const Duration(milliseconds: 100));
      await _speech.stop();

      return 'On-device STT test completed successfully. Local STT available: $_localSttAvailable, Selected locale: $_selectedLocaleId';
    } catch (e) {
      // on-device STT test failed
      return 'On-device STT test failed: $e';
    }
  }

  String? get selectedLocaleId => _selectedLocaleId;
  List<LocaleName> get locales => _locales;

  void setLocale(String? localeId) {
    _selectedLocaleId = localeId;
  }

  Stream<String> startListening() {
    if (!_isInitialized) {
      throw Exception('Voice input not initialized');
    }

    if (_isListening) {
      unawaited(stopListening());
    }

    _textStreamController = StreamController<String>.broadcast();
    _currentText = '';
    _isListening = true;
    _intensityController = StreamController<int>.broadcast();
    _lastIntensity = 0;
    _usingServerStt = false;

    _startIntensityDecayTimer();

    final bool canUseLocal = _localSttAvailable;
    final bool serverAvailable = hasServerStt;
    final bool shouldUseLocal =
        canUseLocal && _preference != SttPreference.serverOnly;
    final bool shouldUseServer =
        serverAvailable &&
        (_preference == SttPreference.serverOnly || !shouldUseLocal);

    if (shouldUseLocal) {
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(const Duration(seconds: 60), () {
        if (_isListening) {
          unawaited(_stopListening());
        }
      });

      Future.microtask(() async {
        try {
          final isStillAvailable = await _speech.isSupported();
          if (!isStillAvailable && _isListening) {
            _localSttAvailable = false;
            if (hasServerStt && allowsServerFallback) {
              unawaited(_beginServerFallback());
            } else {
              unawaited(_stopListening());
            }
          }
        } catch (_) {
          // ignore availability check errors
        }
      });

      _sttResultSub = _speech.onResultChanged.listen((SttRecognition result) {
        if (!_isListening) return;
        final prevLen = _currentText.length;
        _currentText = result.text;
        _textStreamController?.add(_currentText);
        final delta = (_currentText.length - prevLen).clamp(0, 50);
        final mapped = (delta / 5.0).ceil();
        _lastIntensity = mapped.clamp(0, 10);
        try {
          _intensityController?.add(_lastIntensity);
        } catch (_) {}
        if (result.isFinal) {
          unawaited(_stopListening());
        }
      }, onError: (_) {});

      _sttStateSub = _speech.onStateChanged.listen((_) {}, onError: (_) {});

      Future(() async {
        try {
          if (_selectedLocaleId != null) {
            await _speech.setLanguage(_selectedLocaleId!);
          }
          await _speech.start(SttRecognitionOptions(punctuation: true));
        } catch (error) {
          _localSttAvailable = false;
          if (!_isListening) return;
          if (hasServerStt && allowsServerFallback) {
            await _beginServerFallback();
          } else {
            _textStreamController?.addError(error);
            await _stopListening();
          }
        }
      });
    } else if (shouldUseServer) {
      _usingServerStt = true;
      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(const Duration(seconds: 90), () {
        if (_isListening) {
          unawaited(_stopListening());
        }
      });
      Future(() async {
        try {
          await _startServerRecording();
        } catch (error) {
          if (!_isListening) return;
          _textStreamController?.addError(error);
          await _stopListening();
        }
      });
    } else {
      final Exception error;
      if (prefersDeviceOnly) {
        error = Exception(
          'On-device speech recognition required but unavailable',
        );
      } else if (prefersServerOnly) {
        error = Exception('Server speech-to-text is not configured');
      } else {
        error = Exception('Speech recognition not available on this device');
      }
      Future.microtask(() {
        _textStreamController?.addError(error);
        unawaited(_stopListening());
      });
    }

    return _textStreamController!.stream;
  }

  /// Centralized entry point to begin voice recognition.
  /// Ensures initialization and microphone permission before starting.
  Future<Stream<String>> beginListening() async {
    await initialize();
    final hasMic = await checkPermissions();
    if (!hasMic) {
      throw Exception('Microphone permission not granted');
    }
    return startListening();
  }

  Future<void> stopListening() async {
    await _stopListening();
  }

  Future<void> _stopListening() async {
    if (!_isListening) return;

    _isListening = false;

    _autoStopTimer?.cancel();
    _autoStopTimer = null;

    _silenceTimer?.cancel();
    _silenceTimer = null;

    _amplitudeFallbackTimer?.cancel();
    _amplitudeFallbackTimer = null;

    if (_usingServerStt) {
      await _finalizeServerRecording();
    } else {
      await _stopLocalStt();
    }

    await _ampSub?.cancel();
    _ampSub = null;

    _intensityDecayTimer?.cancel();
    _intensityDecayTimer = null;
    _lastIntensity = 0;

    if (!_usingServerStt && _currentText.isNotEmpty) {
      _textStreamController?.add(_currentText);
    }

    await _closeControllers();

    _usingServerStt = false;
    _hasDetectedSpeech = false;
    _vadPaused = false;
  }

  Future<void> _stopLocalStt() async {
    if (_sttResultSub != null) {
      try {
        await _sttResultSub?.cancel();
      } catch (_) {}
      _sttResultSub = null;
    }
    if (_sttStateSub != null) {
      try {
        await _sttStateSub?.cancel();
      } catch (_) {}
      _sttStateSub = null;
    }

    if (_localSttAvailable) {
      try {
        await _speech.stop();
      } catch (_) {}
    }
  }

  Future<void> _beginServerFallback() async {
    if (!allowsServerFallback) {
      _textStreamController?.addError(
        Exception('Server speech-to-text disabled in preferences'),
      );
      await _stopListening();
      return;
    }
    await _stopLocalStt();
    if (!hasServerStt) {
      _textStreamController?.addError(
        Exception('Server speech-to-text unavailable'),
      );
      await _stopListening();
      return;
    }

    _usingServerStt = true;
    _autoStopTimer?.cancel();
    _autoStopTimer = Timer(const Duration(seconds: 90), () {
      if (_isListening) {
        unawaited(_stopListening());
      }
    });

    try {
      await _startServerRecording();
    } catch (error) {
      _textStreamController?.addError(error);
      await _stopListening();
    }
  }

  Future<void> _startServerRecording() async {
    final path = await _createRecordingPath();
    _hasDetectedSpeech = false;

    await _recorder.startRecording(path);

    await _ampSub?.cancel();
    _amplitudeFallbackTimer?.cancel();
    _amplitudeCallbackCount = 0;

    _ampSub = _recorder.amplitudeStream.listen((amplitude) {
      _amplitudeCallbackCount++;
      if (!_isListening) return;

      _lastIntensity = _normalizedToIntensity(amplitude);
      try {
        _intensityController?.add(_lastIntensity);
      } catch (_) {}

      _handleServerAmplitude(amplitude);
    });

    _amplitudeFallbackTimer = Timer(const Duration(seconds: 1), () {
      if (_amplitudeCallbackCount == 0) {
        _silenceTimer = Timer(const Duration(seconds: 15), () {
          if (_isListening && _usingServerStt) {
            unawaited(_stopListening());
          }
        });
      }
    });
  }

  void _handleServerAmplitude(double amplitude) {
    if (!_usingServerStt || !_isListening) return;

    const double speechThreshold = 0.55;
    if (amplitude.isNaN || amplitude.isInfinite) return;

    // If VAD is paused, don't process amplitude for auto-stop
    if (_vadPaused) {
      _silenceTimer?.cancel();
      _silenceTimer = null;
      return;
    }

    if (amplitude > speechThreshold) {
      _hasDetectedSpeech = true;
      _silenceTimer?.cancel();
      _silenceTimer = null;
    } else if (_hasDetectedSpeech && _silenceTimer == null) {
      final silenceDuration = _ref?.read(appSettingsProvider).voiceSilenceDuration ?? 2000;
      _silenceTimer = Timer(Duration(milliseconds: silenceDuration), () {
        if (_isListening && _usingServerStt && !_vadPaused) {
          unawaited(_stopListening());
        }
      });
    }
  }

  /// Pause VAD auto-stop functionality (for "hold to think" mode)
  void pauseVad() {
    if (!_isListening || !_usingServerStt) return;
    _vadPaused = true;
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Resume VAD auto-stop functionality
  void resumeVad() {
    if (!_isListening || !_usingServerStt) return;
    _vadPaused = false;
    // Reset detection state so user gets fresh silence timeout
    _hasDetectedSpeech = false;
  }

  /// Manually submit current recording (for tap-to-submit in VAD mode)
  Future<void> submitRecording() async {
    if (!_isListening) return;
    await _stopListening();
  }

  Future<String> _createRecordingPath() async {
    final directory = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'conduit_voice_$timestamp.m4a';
    return p.join(directory.path, fileName);
  }

  Future<void> _finalizeServerRecording() async {
    final api = _api;
    if (api == null) return;

    final path = await _recorder.stopRecording();
    if (path == null || path.isEmpty) return;

    final file = File(path);
    try {
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;

      final response = await api.transcribeSpeech(
        audioBytes: bytes,
        fileName: p.basename(path),
        mimeType: 'audio/mp4',
        language: _languageForServer(),
      );

      final transcript = _extractTranscriptionText(response);
      if (transcript != null && transcript.trim().isNotEmpty) {
        _currentText = transcript.trim();
        _textStreamController?.add(_currentText);
      } else {
        throw StateError('Empty transcription result');
      }
    } catch (error) {
      _textStreamController?.addError(error);
    } finally {
      unawaited(_cleanupRecordingFile(file));
    }
  }

  Future<void> _cleanupRecordingFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String? _languageForServer() {
    final locale = _selectedLocaleId;
    if (locale != null && locale.isNotEmpty) {
      final primary = locale.split(RegExp('[-_]')).first.toLowerCase();
      if (primary.length >= 2) {
        return primary;
      }
    }
    try {
      final fallback = WidgetsBinding.instance.platformDispatcher.locale;
      final primary = fallback.languageCode.toLowerCase();
      if (primary.isNotEmpty) {
        return primary;
      }
    } catch (_) {}
    return null;
  }

  String? _extractTranscriptionText(Map<String, dynamic> data) {
    final direct = data['text'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct;
    }

    final display = data['display_text'] ?? data['DisplayText'];
    if (display is String && display.trim().isNotEmpty) {
      return display;
    }

    final result = data['result'];
    if (result is Map<String, dynamic>) {
      final resultText = result['text'];
      if (resultText is String && resultText.trim().isNotEmpty) {
        return resultText;
      }
    }

    final combined = data['combinedRecognizedPhrases'];
    if (combined is List && combined.isNotEmpty) {
      final first = combined.first;
      if (first is Map<String, dynamic>) {
        final candidate =
            first['display'] ??
            first['Display'] ??
            first['transcript'] ??
            first['text'];
        if (candidate is String && candidate.trim().isNotEmpty) {
          return candidate;
        }
      } else if (first is String && first.trim().isNotEmpty) {
        return first;
      }
    }

    final results = data['results'];
    if (results is Map<String, dynamic>) {
      final channels = results['channels'];
      if (channels is List && channels.isNotEmpty) {
        final channel = channels.first;
        if (channel is Map<String, dynamic>) {
          final alternatives = channel['alternatives'];
          if (alternatives is List && alternatives.isNotEmpty) {
            final alternative = alternatives.first;
            if (alternative is Map<String, dynamic>) {
              final transcript =
                  alternative['transcript'] ?? alternative['text'];
              if (transcript is String && transcript.trim().isNotEmpty) {
                return transcript;
              }
            }
          }
        }
      }
    }

    final segments = data['segments'];
    if (segments is List && segments.isNotEmpty) {
      final buffer = StringBuffer();
      for (final segment in segments) {
        if (segment is Map<String, dynamic>) {
          final text = segment['text'];
          if (text is String && text.trim().isNotEmpty) {
            buffer.write(text.trim());
            buffer.write(' ');
          }
        } else if (segment is String && segment.trim().isNotEmpty) {
          buffer.write(segment.trim());
          buffer.write(' ');
        }
      }
      final combinedText = buffer.toString().trim();
      if (combinedText.isNotEmpty) {
        return combinedText;
      }
    }

    return null;
  }

  int _normalizedToIntensity(double value) {
    if (value.isNaN || value.isInfinite) return 0;
    return (value * 10).round().clamp(0, 10);
  }

  Future<void> _closeControllers() async {
    if (_textStreamController != null) {
      try {
        await _textStreamController?.close();
      } catch (_) {}
      _textStreamController = null;
    }
    if (_intensityController != null) {
      try {
        await _intensityController?.close();
      } catch (_) {}
      _intensityController = null;
    }
  }

  void _startIntensityDecayTimer() {
    _intensityDecayTimer?.cancel();
    _intensityDecayTimer = Timer.periodic(const Duration(milliseconds: 120), (
      _,
    ) {
      if (!_isListening) return;
      if (_lastIntensity <= 0) return;
      _lastIntensity = (_lastIntensity - 1).clamp(0, 10);
      try {
        _intensityController?.add(_lastIntensity);
      } catch (_) {}
    });
  }

  void dispose() {
    stopListening();
    _silenceTimer?.cancel();
    try {
      _speech.dispose().catchError((_) {});
    } catch (_) {}
  }
}

final voiceInputServiceProvider = Provider<VoiceInputService>((ref) {
  final api = ref.watch(apiServiceProvider);
  final service = VoiceInputService(api: api, ref: ref);
  final currentSettings = ref.read(appSettingsProvider);
  service.updatePreference(currentSettings.sttPreference);
  ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
    if (previous?.sttPreference != next.sttPreference) {
      service.updatePreference(next.sttPreference);
    }
  });
  ref.onDispose(service.dispose);
  return service;
});

@Riverpod(keepAlive: true)
Future<bool> voiceInputAvailable(Ref ref) async {
  final service = ref.watch(voiceInputServiceProvider);
  if (!service.isSupportedPlatform) return false;
  final initialized = await service.initialize();
  if (!initialized) return false;
  switch (service.preference) {
    case SttPreference.deviceOnly:
      return service.hasLocalStt;
    case SttPreference.serverOnly:
      return service.hasServerStt;
    case SttPreference.auto:
      if (service.hasLocalStt) return true;
      if (!service.hasServerStt) return false;
      break;
  }
  final hasPermission = await service.checkPermissions();
  if (!hasPermission) return false;
  return service.isAvailable;
}

final voiceInputStreamProvider = StreamProvider<String>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.textStream;
});

/// Stream of crude voice intensity for waveform visuals
final voiceIntensityStreamProvider = StreamProvider<int>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.intensityStream;
});

final localVoiceRecognitionAvailableProvider = FutureProvider<bool>((
  ref,
) async {
  final service = ref.watch(voiceInputServiceProvider);
  final initialized = await service.initialize();
  if (!initialized) return false;
  if (service.hasLocalStt) return true;
  return service.checkOnDeviceSupport();
});

final serverVoiceRecognitionAvailableProvider = Provider<bool>((ref) {
  final service = ref.watch(voiceInputServiceProvider);
  return service.hasServerStt;
});
