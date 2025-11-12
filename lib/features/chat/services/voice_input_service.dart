import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:stts/stts.dart';
import 'package:vad/vad.dart';

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
  static const int _vadSampleRate = 16000;
  static const int _vadFrameSamples = 1536;

  final VadHandler _vadHandler = VadHandler.create();
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
  List<double>? _vadPendingSamples;

  Stream<String> get textStream =>
      _textStreamController?.stream ?? const Stream<String>.empty();
  Timer? _autoStopTimer;
  StreamSubscription<SttRecognition>? _sttResultSub;
  StreamSubscription<SttState>? _sttStateSub;
  StreamSubscription<List<double>>? _vadSpeechEndSub;
  StreamSubscription<({double isSpeech, double notSpeech, List<double> frame})>?
  _vadFrameSub;
  StreamSubscription<String>? _vadErrorSub;

  bool get isSupportedPlatform => Platform.isAndroid || Platform.isIOS;
  bool get hasServerStt => _api != null;
  SttPreference get preference => _preference;
  bool get allowsServerFallback => _preference != SttPreference.deviceOnly;
  bool get prefersServerOnly => _preference == SttPreference.serverOnly;
  bool get prefersDeviceOnly => _preference == SttPreference.deviceOnly;

  VoiceInputService({ApiService? api, Ref? ref}) : _api = api, _ref = ref;

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

    if (_usingServerStt) {
      await _stopVadRecording();
      final samples = _vadPendingSamples;
      _vadPendingSamples = null;
      if (samples != null && samples.isNotEmpty) {
        await _processVadSamples(samples);
      }
    } else {
      await _stopLocalStt();
      if (_currentText.isNotEmpty) {
        _textStreamController?.add(_currentText);
      }
    }

    _intensityDecayTimer?.cancel();
    _intensityDecayTimer = null;
    _lastIntensity = 0;

    await _closeControllers();

    _usingServerStt = false;
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
    await _setupVadStreams();
    final settings = _ref?.read(appSettingsProvider);
    final silenceMs = settings?.voiceSilenceDuration ?? 2000;
    final redemptionFrames = _silenceDurationToFrames(silenceMs);
    final endPadFrames = redemptionFrames > 4
        ? (redemptionFrames / 4).round().clamp(1, redemptionFrames)
        : 1;

    try {
      await _vadHandler.startListening(
        frameSamples: _vadFrameSamples,
        redemptionFrames: redemptionFrames,
        endSpeechPadFrames: endPadFrames,
        preSpeechPadFrames: 2,
        minSpeechFrames: 3,
        submitUserSpeechOnPause: true,
        recordConfig: const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _vadSampleRate,
          numChannels: 1,
          bitRate: 16,
          echoCancel: true,
          autoGain: true,
          noiseSuppress: true,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeInCommunication,
            speakerphone: true,
            manageBluetooth: true,
            useLegacy: false,
          ),
        ),
      );
    } catch (error) {
      _textStreamController?.addError(error);
      rethrow;
    }
  }

  Future<void> _setupVadStreams() async {
    await _vadSpeechEndSub?.cancel();
    _vadSpeechEndSub = _vadHandler.onSpeechEnd.listen((samples) {
      if (!_isListening || !_usingServerStt) return;
      if (samples.isEmpty) return;
      _vadPendingSamples = samples;
      if (_isListening) {
        unawaited(_stopListening());
      }
    });

    await _vadFrameSub?.cancel();
    _vadFrameSub = _vadHandler.onFrameProcessed.listen((frameData) {
      if (!_isListening) return;
      final intensity = _intensityFromVadFrame(frameData.frame);
      _lastIntensity = intensity;
      try {
        _intensityController?.add(_lastIntensity);
      } catch (_) {}
    });

    await _vadErrorSub?.cancel();
    _vadErrorSub = _vadHandler.onError.listen((message) {
      _textStreamController?.addError(Exception(message));
      if (_isListening) {
        unawaited(_stopListening());
      }
    });
  }

  Future<void> _stopVadRecording() async {
    try {
      await _vadHandler.stopListening();
    } catch (_) {}
    await _vadSpeechEndSub?.cancel();
    _vadSpeechEndSub = null;
    await _vadFrameSub?.cancel();
    _vadFrameSub = null;
    await _vadErrorSub?.cancel();
    _vadErrorSub = null;
  }

  Future<void> _processVadSamples(List<double> samples) async {
    final api = _api;
    if (api == null) return;

    try {
      final wavBytes = _samplesToWav(samples);
      final fileName =
          'conduit_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

      final response = await api.transcribeSpeech(
        audioBytes: wavBytes,
        fileName: fileName,
        mimeType: 'audio/wav',
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
    }
  }

  int _silenceDurationToFrames(int milliseconds) {
    final frameDurationMs = (_vadFrameSamples / _vadSampleRate) * 1000;
    final frames = (milliseconds / frameDurationMs).round();
    return frames.clamp(4, 50);
  }

  int _intensityFromVadFrame(List<double> frame) {
    if (frame.isEmpty) return 0;
    double peak = 0;
    for (final sample in frame) {
      final value = sample.abs();
      if (value > peak) {
        peak = value;
      }
    }
    final scaled = (peak * 12).round();
    return scaled.clamp(0, 10);
  }

  Uint8List _samplesToWav(List<double> samples) {
    if (samples.isEmpty) {
      return Uint8List(0);
    }
    final Int16List pcm = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      final scaled = (clamped * 32767).round().clamp(-32768, 32767);
      pcm[i] = scaled;
    }

    final dataLength = pcm.lengthInBytes;
    final bytesPerSample = 2;
    final numChannels = 1;
    final byteRate = _vadSampleRate * numChannels * bytesPerSample;
    final blockAlign = numChannels * bytesPerSample;

    final builder = BytesBuilder();
    builder.add(ascii.encode('RIFF'));
    builder.add(_int32Le(36 + dataLength));
    builder.add(ascii.encode('WAVE'));
    builder.add(ascii.encode('fmt '));
    builder.add(_int32Le(16));
    builder.add(_int16Le(1));
    builder.add(_int16Le(numChannels));
    builder.add(_int32Le(_vadSampleRate));
    builder.add(_int32Le(byteRate));
    builder.add(_int16Le(blockAlign));
    builder.add(_int16Le(16));
    builder.add(ascii.encode('data'));
    builder.add(_int32Le(dataLength));
    builder.add(Uint8List.view(pcm.buffer));
    return builder.toBytes();
  }

  List<int> _int16Le(int value) => [value & 0xff, (value >> 8) & 0xff];

  List<int> _int32Le(int value) => [
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];

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
    unawaited(_vadHandler.dispose());
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
