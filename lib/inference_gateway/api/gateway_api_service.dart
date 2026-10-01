import 'dart:typed_data';

import 'package:conduit_core/services/api_service.dart';
import '../router/gateway_inference_router.dart';

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
