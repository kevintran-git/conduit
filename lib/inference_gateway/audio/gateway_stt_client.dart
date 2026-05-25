import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';

import '../transport/gateway_client.dart';
import '../transport/gateway_exception.dart';

/// REST `/v1/audio/transcriptions` — single-blob multipart upload.
/// Returns the OpenAI-shaped `{text: ...}` map so the existing
/// `transcribeSpeech` callers don't notice the swap.
class GatewaySttClient {
  GatewaySttClient(this._client);

  final GatewayClient _client;

  Future<Map<String, dynamic>> transcribe({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) async {
    if (audioBytes.isEmpty) {
      throw ArgumentError('audioBytes cannot be empty for transcription');
    }
    final name = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : 'audio.m4a';
    final mime = (mimeType != null && mimeType.trim().isNotEmpty)
        ? mimeType.trim()
        : _inferMime(name);

    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        audioBytes,
        filename: name,
        contentType: MediaType.parse(mime),
      ),
      'model': 'whisper-1',
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
    });

    final response = await _client.dio.post<dynamic>(
      '/v1/audio/transcriptions',
      data: form,
      options: Options(headers: const {'accept': 'application/json'}),
    );

    // GatewayClient sets validateStatus < 600 so 4xx/5xx bodies arrive here
    // as "success." Re-validate explicitly so an auth error becomes a real
    // exception instead of being returned as the transcription Map.
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw GatewayHttpException(
        path: '/v1/audio/transcriptions',
        statusCode: status,
        body: response.data?.toString() ?? '',
      );
    }

    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) return {'text': data};
    throw StateError('Unexpected transcription response: ${data.runtimeType}');
  }

  String _inferMime(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.webm')) return 'audio/webm';
    return 'audio/m4a';
  }
}
