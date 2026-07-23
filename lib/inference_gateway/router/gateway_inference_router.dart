import 'dart:typed_data';

import 'package:inference_kit/inference_kit.dart' as ik;

/// Single entry point used by `ApiService` shim points to delegate speech
/// requests to the gateway. Holds live "is this service active" predicates
/// rather than booleans so the router always sees the current toggle state
/// without needing re-construction.
class GatewayInferenceRouter {
  GatewayInferenceRouter({
    required this.stt,
    required this.tts,
    required bool Function() sttActive,
    required bool Function() ttsActive,
  }) : _sttActive = sttActive,
       _ttsActive = ttsActive;

  final ik.TranscriptionClient stt;
  final ik.TextToSpeechClient tts;
  final bool Function() _sttActive;
  final bool Function() _ttsActive;

  bool get isSttActive => _sttActive();
  bool get isTtsActive => _ttsActive();

  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) {
    return stt.transcribe(
      audioBytes: audioBytes,
      fileName: fileName,
      mimeType: mimeType,
      language: language,
    );
  }

  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    String? model,
    double? speed,
  }) {
    return tts.synthesize(text: text, voice: voice, model: model, speed: speed);
  }
}
