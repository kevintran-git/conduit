import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:inference_kit/read_aloud.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart' show TtsEngine;
import 'package:conduit_core/utils/debug_logger.dart';

import '../../features/chat/services/text_to_speech_service.dart';
import '../../features/chat/services/tts_manager.dart';
import '../../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../config/gateway_catalog.dart';
import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';
import '../router/gateway_router_providers.dart';
import '../read_aloud/presentation/read_aloud_overlay.dart';
import '../read_aloud/device_read_aloud.dart';
import '../read_aloud/read_aloud_adapters.dart';
import '../read_aloud/read_aloud_settings_provider.dart';
import '../read_aloud/read_aloud_store.dart';
import 'gateway_chat_tts_speaker.dart';

class ReadAloudNotice {
  const ReadAloudNotice(
    this.message, {
    this.error = false,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final bool error;
  final String? actionLabel;
  final VoidCallback? onAction;
}

class GatewayTextToSpeechService extends TextToSpeechService {
  GatewayTextToSpeechService({
    required Ref ref,
    super.serverSpeech,
    super.backendConfig,
    super.loadBackendConfig,
  }) : _ref = ref;

  final Ref _ref;
  GatewayChatTtsSpeaker? _speaker;
  ik.ElevenLabsTtsClient? _speakerClient;
  ReadAloudEngine? _engine;
  String? _engineEndpoint;
  ConduitReadAloudHost? _engineHost;
  ReadAloudOverlayHost? _overlay;

  final ValueNotifier<ReadAloudSnapshot?> readAloud = ValueNotifier(null);
  final ValueNotifier<ReadAloudNotice?> readAloudNotice = ValueNotifier(null);
  Timer? _noticeTimer;
  Timer? _settingsRestart;
  String? _lastText;
  bool _onDevice = false;
  Future<bool> Function()? _initDevice;
  DeviceReadAloud? _device;
  List<String>? _voices;
  DateTime _deviceRestartAt = DateTime.fromMillisecondsSinceEpoch(0);

  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;
  void Function(int sentenceIndex)? _onSentenceIndex;
  void Function(int start, int end)? _onWordProgress;

  int _lastPart = -1;
  bool _pauseNotified = false;

  bool get _gatewayActive => _ref.read(gatewayTtsActiveProvider);

  bool get _readAloudActive => _engine?.isActive ?? false;

  GatewayChatTtsSpeaker _ensureSpeaker() {
    final liveClient = _ref.read(gatewayElevenLabsClientProvider);
    if (_speaker != null && !identical(_speakerClient, liveClient)) {
      unawaited(_speaker!.dispose());
      _speaker = null;
    }
    _speakerClient = liveClient;
    return _speaker ??= GatewayChatTtsSpeaker(
      client: liveClient,
      config: _ref.read(gatewayConfigProvider),
    );
  }

  Future<ReadAloudEngine> _ensureEngine() async {
    final config = _ref.read(gatewayConfigProvider);
    final endpoint = '${config.baseUrl}\u0000${config.apiKey}';
    final stale = _engine;
    if (stale != null && _engineEndpoint != endpoint) {
      _engine = null;
      await stale.dispose();
      await _engineHost?.dispose();
      readAloud.value = null;
    }
    _engineEndpoint = endpoint;
    final existing = _engine;
    if (existing != null) return existing;
    final host = _engineHost = ConduitReadAloudHost();
    final engine = ReadAloudEngine(
      source: GatewaySpeechSource(
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
      ),
      output: SpeakerPcmOutput(),
      cache: TtsReadAloudCache(),
      prefs: ReadAloudStore(),
      host: host,
    );
    host.engine = engine;
    engine.settings = _ref.read(readAloudSettingsProvider);
    engine.onStarted = () => _onStart?.call();
    engine.onStatus = _handleReadAloudStatus;
    engine.onCompleted = () {
      _lastPart = -1;
      _onComplete?.call();
      _releaseWakelockIfIdle();
    };
    engine.onError = (message, heard) {
      _lastPart = -1;
      if (heard) {
        _failReadAloud(message);
      } else {
        unawaited(_speakOnDevice(message));
      }
    };
    engine.onVoiceRejected = (voice) {
      _showNotice(
        ReadAloudNotice(
          'Voice "$voice" isn\'t available on the gateway. '
          'Switched to the default voice.',
        ),
      );
      unawaited(_forgetMissingVoice(voice));
    };
    engine.onResumedFromMark = () => _showNotice(
      ReadAloudNotice(
        'Picking up where you left off.',
        actionLabel: 'Start over',
        onAction: () => unawaited(engine.seekTo(Duration.zero)),
      ),
    );
    engine.onWord = (part, start, end) {
      if (part != _lastPart) {
        _lastPart = part;
        _onSentenceIndex?.call(part);
      }
      _onWordProgress?.call(start, end);
    };
    engine.snapshot.addListener(() {
      if (identical(_engine, engine) && _device == null) {
        readAloud.value = engine.snapshot.value;
      }
    });
    return _engine = engine;
  }

  void _applySettings(ReadAloudSettings next) {
    final engine = _engine;
    if (engine == null) return;
    final restart = engine.settings.synthesisDiffers(next);
    engine.settings = next;
    if (restart) _restartReading(const Duration(milliseconds: 800));
  }

  void _restartReading(Duration delay) {
    final engine = _engine;
    if (engine == null || !engine.isActive) return;
    _settingsRestart?.cancel();
    _settingsRestart = Timer(delay, () {
      final text = _lastText;
      final segment = engine.snapshot.value?.segment;
      if (!identical(_engine, engine) || !engine.isActive) return;
      if (text == null || segment == null || _device != null) return;
      readAloudTrace('restart', {});
      unawaited(_speakGateway(text, startSegment: segment));
    });
  }

  void _showNotice(ReadAloudNotice notice) {
    _noticeTimer?.cancel();
    readAloudNotice.value = notice;
    _noticeTimer = Timer(
      Duration(seconds: notice.error ? 10 : 6),
      dismissReadAloudNotice,
    );
  }

  void dismissReadAloudNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    readAloudNotice.value = null;
  }

  void _failReadAloud(String message) {
    _showNotice(ReadAloudNotice('Read aloud stopped. $message', error: true));
    _onError?.call(message);
    _releaseWakelockIfIdle();
  }

  Future<void> _speakOnDevice(String reason) async {
    final text = _lastText;
    final init = _initDevice;
    if (text == null || init == null) {
      _failReadAloud(reason);
      return;
    }
    _onDevice = true;
    readAloudTrace('device-fallback', {'reason': reason});
    try {
      final available = await init();
      if (!_onDevice) return;
      if (!available) {
        _onDevice = false;
        _failReadAloud(reason);
        return;
      }
      final config = _ref.read(gatewayConfigProvider);
      final settings = _ref.read(readAloudSettingsProvider);
      final missingHost = await _unresolvableHost(config.baseUrl);
      if (!_onDevice) return;
      final device = _device = DeviceReadAloud(
        plan: ReadAloudPlan.build(
          fullText: text,
          parts: splitTextForSpeech(text),
          pronunciations: parsePronunciations(settings.pronunciations),
          skip: settings.skip,
        ),
        speak: (value) async {
          _deviceRestartAt = DateTime.now();
          if (TtsManager.instance.isPlaying) {
            await super.stop();
            await Future<void>.delayed(const Duration(milliseconds: 150));
            _deviceRestartAt = DateTime.now();
          }
          return super.speak(value);
        },
        pause: () => super.pause(),
        resume: () => super.resume(),
      );
      device.snapshot.addListener(() {
        if (identical(_device, device)) readAloud.value = device.snapshot.value;
      });
      _showNotice(
        missingHost == null
            ? ReadAloudNotice(
                '$reason Reading with the device voice instead.',
                actionLabel: 'Retry gateway',
                onAction: () => unawaited(retryGatewayVoice()),
              )
            : ReadAloudNotice(
                'Can\'t find the gateway at $missingHost. '
                'Reading with the device voice instead.',
                error: true,
                actionLabel:
                    'Use ${Uri.parse(GatewayConfig.defaultBaseUrl).host}',
                onAction: () => unawaited(_useDefaultGateway()),
              ),
      );
      await device.start(0);
    } catch (error) {
      _closeDevice();
      _onDevice = false;
      _failReadAloud(reason);
    }
  }

  bool get readingOnDevice => _device != null;

  Future<String?> _unresolvableHost(String baseUrl) async {
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    final fallback = Uri.parse(GatewayConfig.defaultBaseUrl).host;
    if (host.isEmpty || host == fallback) return null;
    if (InternetAddress.tryParse(host) != null) return null;
    if (await _resolves(host) || !await _resolves(fallback)) return null;
    return host;
  }

  Future<void> _useDefaultGateway() async {
    await _ref
        .read(gatewayConfigProvider.notifier)
        .setBaseUrl(GatewayConfig.defaultBaseUrl);
    readAloudTrace('gateway-address-reset', {});
    await retryGatewayVoice();
  }

  Future<bool> _resolves(String host) async {
    try {
      final found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 3));
      return found.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> retryGatewayVoice() async {
    final device = _device;
    final text = _lastText;
    if (device == null || text == null) return;
    final segment = device.segment;
    _closeDevice();
    _onDevice = false;
    _deviceRestartAt = DateTime.now();
    await super.stop();
    await _speakGateway(text, startSegment: segment);
  }

  void _closeDevice() {
    final device = _device;
    if (device == null) return;
    _device = null;
    device.close();
    readAloud.value = _engine?.snapshot.value;
  }

  bool get _restartingDevice =>
      DateTime.now().difference(_deviceRestartAt) < const Duration(seconds: 2);

  Future<void> _forgetMissingVoice(String voice) async {
    try {
      final catalog = await _ref
          .read(gatewayCatalogProvider.future)
          .timeout(const Duration(seconds: 5));
      if (catalog.voices.isEmpty || catalog.voices.contains(voice)) return;
      if (_ref.read(gatewayConfigProvider).ttsVoice != voice) return;
      _ref.read(gatewayConfigProvider.notifier).setTtsVoice('');
    } catch (_) {}
  }

  void _handleReadAloudStatus(ReadAloudStatus status) {
    switch (status) {
      case ReadAloudStatus.playing:
        unawaited(WakelockPlus.enable());
        if (_pauseNotified) {
          _pauseNotified = false;
          _onContinue?.call();
        }
      case ReadAloudStatus.paused:
        _pauseNotified = true;
        _onPause?.call();
        _releaseWakelockIfIdle();
      case ReadAloudStatus.loading:
        break;
    }
  }

  @override
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
    _onWordProgress = onDeviceWordProgress;
    super.bindHandlers(
      onStart: onStart,
      onComplete: () {
        _closeDevice();
        _onComplete?.call();
      },
      onCancel: () {
        if (_device != null && _restartingDevice) return;
        _closeDevice();
        _onCancel?.call();
      },
      onPause: () {
        _device?.onPaused();
        _onPause?.call();
      },
      onContinue: () {
        _device?.onResumed();
        _onContinue?.call();
      },
      onError: (message) {
        _closeDevice();
        _onError?.call(message);
      },
      onSentenceIndex: (index) {
        _device?.onChunk(index);
        _onSentenceIndex?.call(index + (_device?.chunkBase ?? 0));
      },
      onDeviceWordProgress: (start, end) {
        _device?.onWord(start);
        _onWordProgress?.call(start, end);
      },
    );
  }

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
    TtsEngine engine = TtsEngine.device,
  }) async {
    _initDevice = () => super.initialize(
      deviceVoice: deviceVoice,
      serverVoice: serverVoice,
      speechRate: speechRate,
      pitch: pitch,
      volume: volume,
      engine: engine,
    );
    if (_gatewayActive) return true;
    return super.initialize(
      deviceVoice: deviceVoice,
      serverVoice: serverVoice,
      speechRate: speechRate,
      pitch: pitch,
      volume: volume,
      engine: engine,
    );
  }

  @override
  Future<void> speak(String text) async {
    _onDevice = false;
    _closeDevice();
    if (!_gatewayActive) {
      await _speaker?.stop();
      await _engine?.stop();
      await super.speak(text);
      return;
    }
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot speak empty text');
    }
    await _speakGateway(text);
  }

  Future<void> _speakGateway(String text, {int? startSegment}) async {
    DebugLogger.log(
      'speak-via-gateway',
      scope: 'gateway/chat-tts',
      data: {'text_len': text.length},
    );
    await _speaker?.stop();
    final config = _ref.read(gatewayConfigProvider);
    _lastPart = -1;
    _pauseNotified = false;
    _lastText = text;
    dismissReadAloudNotice();
    _overlay ??= ReadAloudOverlayHost(service: this);
    unawaited(WakelockPlus.enable());
    final engine = await _ensureEngine();
    engine.settings = _ref.read(readAloudSettingsProvider);
    await engine.play(
      text: text,
      parts: splitTextForSpeech(text),
      voice: config.ttsVoice,
      model: config.ttsModel,
      startSegment: startSegment,
    );
    if (!engine.isActive) _releaseWakelockIfIdle();
  }

  @override
  Future<void> startStreamingTts() async {
    if (!_gatewayActive) {
      await super.startStreamingTts();
      return;
    }
    DebugLogger.log('stream-start-via-gateway', scope: 'gateway/chat-tts');
    await _engine?.stop();
    unawaited(WakelockPlus.enable());
    await _ensureSpeaker().startStream(
      onStart: _onStart,
      onComplete: _onComplete,
      onError: _onError,
    );
  }

  @override
  Future<void> feedStreamingText(String accumulatedText) async {
    if (!_gatewayActive) {
      await super.feedStreamingText(accumulatedText);
      return;
    }
    _speaker?.feed(accumulatedText);
  }

  @override
  Future<void> finishStreamingTts({String? finalText}) async {
    if (!_gatewayActive) {
      await super.finishStreamingTts(finalText: finalText);
      return;
    }
    try {
      await _speaker?.finishStream(finalText: finalText);
    } finally {
      _releaseWakelockIfIdle();
    }
  }

  @override
  Future<void> stopStreamingTts() async {
    if (!_gatewayActive) {
      await super.stopStreamingTts();
      return;
    }
    await _speaker?.stop();
    _onCancel?.call();
    _releaseWakelockIfIdle();
  }

  void _releaseWakelockIfIdle() {
    final callActive = _ref.read(chatVoiceModeControllerProvider).isActive;
    if (!callActive) {
      unawaited(WakelockPlus.disable());
    }
  }

  @override
  Future<void> stop() async {
    _onDevice = false;
    _closeDevice();
    dismissReadAloudNotice();
    if (_speaker != null || _engine != null) {
      await _engine?.stop();
      await _speaker?.stop();
      _lastPart = -1;
      _pauseNotified = false;
      _onCancel?.call();
      _releaseWakelockIfIdle();
    }
    await super.stop();
  }

  @override
  Future<void> pause() async {
    if (_readAloudActive) {
      await _engine!.pause();
      return;
    }
    if (_gatewayActive && (_speaker?.isStreaming ?? false)) {
      await _speaker!.stop();
      _onCancel?.call();
      _releaseWakelockIfIdle();
      return;
    }
    await super.pause();
  }

  @override
  Future<void> resume() async {
    if (_readAloudActive) {
      unawaited(WakelockPlus.enable());
      await _engine!.resume();
      return;
    }
    if (_gatewayActive && !_onDevice) return;
    await super.resume();
  }

  bool get readAloudPaused => _device?.isPaused ?? _engine?.isPaused ?? false;

  Future<void> togglePause() async {
    final device = _device;
    if (device != null) return device.togglePause();
    return readAloudPaused ? resume() : pause();
  }

  Future<void> seek(Duration position) async {
    final device = _device;
    if (device != null) return device.seekTo(position);
    await _engine?.seekTo(position);
  }

  Future<void> skipBy(Duration delta) async {
    final device = _device;
    if (device != null) return device.skipBy(delta);
    await _engine?.skipBy(delta);
  }

  Future<void> skipSegments(int delta) async {
    final device = _device;
    if (device != null) return device.skipSegments(delta);
    await _engine?.skipSegments(delta);
  }

  String get readAloudVoice => _ref.read(gatewayConfigProvider).ttsVoice;

  Future<List<String>> readAloudVoices() async {
    final known = _voices;
    if (known != null && known.isNotEmpty) return known;
    final catalog = await _ref
        .read(gatewayCatalogProvider.future)
        .timeout(const Duration(seconds: 8));
    return _voices = catalog.voices;
  }

  Future<void> switchReadAloudVoice(String voice) async {
    await _ref.read(gatewayConfigProvider.notifier).setTtsVoice(voice);
  }

  Future<void> setReadAloudSpeed(double speed) async {
    await _engine?.setSpeed(speed);
  }

  Future<void> playSegment(int segment, {int word = 0}) async {
    final device = _device;
    if (device != null) return device.start(segment);
    if (_engine?.isPaused ?? false) unawaited(WakelockPlus.enable());
    await _engine?.playSegment(segment, word: word);
  }

  @override
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_gatewayActive) return super.getAvailableVoices();
    try {
      return [
        for (final voice in await readAloudVoices())
          {'id': voice, 'name': voice},
      ];
    } catch (_) {
      final current = _ref.read(gatewayConfigProvider).ttsVoice;
      return [
        if (current.isNotEmpty) {'id': current, 'name': current},
      ];
    }
  }

  @override
  Future<void> dispose() async {
    _settingsRestart?.cancel();
    _overlay?.dispose();
    _overlay = null;
    await _speaker?.dispose();
    _speaker = null;
    final engine = _engine;
    _engine = null;
    await engine?.dispose();
    await _engineHost?.dispose();
    _noticeTimer?.cancel();
    readAloud.dispose();
    readAloudNotice.dispose();
    await super.dispose();
  }
}

TextToSpeechService createGatewayTextToSpeechService(Ref ref) {
  BackendConfig? readBackendConfig() {
    return ref
        .read(backendConfigProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
  }

  final service = GatewayTextToSpeechService(
    ref: ref,
    serverSpeech: ref.read(serverSpeechProviderProvider),
    backendConfig: readBackendConfig(),
    loadBackendConfig: () async {
      await ref.read(backendConfigProvider.notifier).refresh();
      return readBackendConfig();
    },
  );
  ref.listen(serverSpeechProviderProvider, (_, next) {
    TtsManager.instance.setServerSpeech(next);
  });
  ref.listen(readAloudSettingsProvider, (_, next) {
    service._applySettings(next);
  });
  ref.listen(
    gatewayConfigProvider.select((c) => (c.ttsVoice, c.ttsModel)),
    (_, _) => service._restartReading(Duration.zero),
  );
  ref.listen(backendConfigProvider, (_, next) {
    service.setBackendConfig(
      next.maybeWhen(data: (value) => value, orElse: () => null),
    );
  });
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
}
