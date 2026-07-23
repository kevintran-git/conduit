import 'dart:typed_data';

import '../../core/services/api_service.dart';
import '../router/gateway_inference_router.dart';

/// `ApiService` subclass that routes speech-to-text and text-to-speech
/// through the inference gateway when those toggles are on. Everything else
/// falls through to the upstream `ApiService` behavior unchanged. Lives
/// entirely under `lib/inference_gateway/` so the core API class stays vanilla
/// and easy to merge with upstream.
class GatewayApiService extends ApiService {
  GatewayApiService({
    required super.serverConfig,
    required super.workerManager,
    super.authToken,
    required this.router,
  });

  final GatewayInferenceRouter router;

  @override
  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) {
    if (router.isSttActive) {
      return router.transcribeSpeech(
        audioBytes: audioBytes,
        fileName: fileName,
        mimeType: mimeType,
        language: language,
      );
    }
    return super.transcribeSpeech(
      audioBytes: audioBytes,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }

  @override
  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) {
    if (router.isTtsActive) {
      return router.generateSpeech(text: text, voice: voice, speed: speed);
    }
    return super.generateSpeech(text: text, voice: voice, speed: speed);
  }
}
