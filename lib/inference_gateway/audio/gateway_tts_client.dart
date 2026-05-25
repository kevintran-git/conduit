import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/utils/debug_logger.dart';
import '../transport/gateway_client.dart';
import '../transport/gateway_exception.dart';
import 'gateway_elevenlabs_tts_client.dart';
import 'pcm_wav_wrapper.dart';

/// Tap-to-speak TTS facade.
///
/// Prefers the ElevenLabs-compatible WebSocket for low TTFB; falls back to
/// REST `/v1/audio/speech` if the WS handshake fails. Returns playable
/// `(bytes, mimeType)` for the existing TtsManager pipeline — raw PCM gets
/// wrapped in a WAV header so just_audio's decoders accept it.
class GatewayTtsClient {
  GatewayTtsClient({
    required GatewayClient client,
    required this.elevenlabs,
    required this.defaults,
  }) : _client = client;

  static const int _wsSampleRateHz = 24000;
  static const String _restPath = '/v1/audio/speech';

  final GatewayClient _client;
  final GatewayElevenLabsTtsClient elevenlabs;
  final GatewayTtsDefaults defaults;

  Future<({Uint8List bytes, String mimeType})> synthesize({
    required String text,
    String? voice,
    String? model,
    double? speed,
  }) async {
    final resolvedVoice = (voice != null && voice.trim().isNotEmpty)
        ? voice.trim()
        : defaults.voice;
    final resolvedModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : defaults.model;

    // Try the WS first — it's the fast path. If anything goes wrong (handshake
    // refused, server kills the socket, empty payload), fall through to REST.
    try {
      final pcm = await elevenlabs.synthesizeFull(
        text: text,
        voice: resolvedVoice,
        model: resolvedModel,
      );
      if (pcm.isNotEmpty) {
        final wav = wrapPcmAsWav(pcm, sampleRate: _wsSampleRateHz);
        return (bytes: wav, mimeType: 'audio/wav');
      }
      DebugLogger.log(
        'ws-empty-payload-falling-back-to-rest',
        scope: 'gateway/tts',
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'ws-failed-falling-back-to-rest',
        scope: 'gateway/tts',
        error: error,
        stackTrace: stackTrace,
      );
    }

    return _restFallback(
      text: text,
      voice: resolvedVoice,
      model: resolvedModel,
      speed: speed,
    );
  }

  /// REST fallback. Asks for `wav` first (lowest-friction container for
  /// just_audio); if the gateway only emits raw PCM, wrap it ourselves.
  Future<({Uint8List bytes, String mimeType})> _restFallback({
    required String text,
    required String voice,
    required String model,
    double? speed,
  }) async {
    final response = await _client.dio.post<dynamic>(
      _restPath,
      data: <String, dynamic>{
        'model': model,
        'input': text,
        'voice': voice,
        'response_format': 'wav',
        'speed': ?speed,
      },
      options: Options(
        responseType: ResponseType.bytes,
        validateStatus: (status) => status != null && status < 600,
      ),
    );

    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      final body = _coerceText(response.data);
      throw GatewayHttpException(
        path: _restPath,
        statusCode: status,
        body: body,
      );
    }

    final raw = response.data;
    Uint8List bytes;
    if (raw is Uint8List) {
      bytes = raw;
    } else if (raw is List<int>) {
      bytes = Uint8List.fromList(raw);
    } else {
      bytes = Uint8List(0);
    }
    final mime =
        response.headers.value('content-type')?.split(';').first.trim() ?? '';

    // If the server actually returned WAV, hand it back as-is. If it returned
    // PCM bytes (some deployments ignore response_format), wrap them.
    if (_looksLikeWav(bytes)) {
      return (bytes: bytes, mimeType: 'audio/wav');
    }
    if (mime.startsWith('audio/') && mime != 'audio/l16') {
      return (bytes: bytes, mimeType: mime);
    }
    final wav = wrapPcmAsWav(bytes, sampleRate: _wsSampleRateHz);
    return (bytes: wav, mimeType: 'audio/wav');
  }

  bool _looksLikeWav(Uint8List bytes) {
    if (bytes.length < 12) return false;
    return bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45;
  }

  String _coerceText(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) {
      try {
        return String.fromCharCodes(data.take(2048));
      } catch (_) {
        return '';
      }
    }
    return data.toString();
  }
}

class GatewayTtsDefaults {
  const GatewayTtsDefaults({required this.model, required this.voice});
  final String model;
  final String voice;
}
