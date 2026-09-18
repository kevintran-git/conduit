import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;

import '../transport/gateway_client.dart';
import 'gateway_providers.dart';

class GatewayAudioModel {
  const GatewayAudioModel({required this.id, required this.backend});

  final String id;

  final String backend;
}

class GatewayCatalog {
  const GatewayCatalog({
    required this.sttModels,
    required this.ttsModels,
    required this.voices,
  });

  final List<GatewayAudioModel> sttModels;
  final List<GatewayAudioModel> ttsModels;
  final List<String> voices;

  static const GatewayCatalog empty = GatewayCatalog(
    sttModels: <GatewayAudioModel>[],
    ttsModels: <GatewayAudioModel>[],
    voices: <String>[],
  );
}

/// needs it.
final gatewayLiveCatalogProvider = FutureProvider<ik.LiveCatalog>((ref) async {
  final cfg = ref.watch(gatewayConfigProvider);
  if (!cfg.hasCredentials) return ik.LiveCatalog.empty;
  final dio = ref.read(gatewayClientProvider).dio;
  return ik.LiveClient.fetchCatalog(dio);
});

final gatewayCatalogProvider = FutureProvider<GatewayCatalog>((ref) async {
  final cfg = ref.watch(gatewayConfigProvider);
  if (!cfg.hasCredentials) return GatewayCatalog.empty;
  final dio = ref.read(gatewayClientProvider).dio;
  final responses = await Future.wait<Response<dynamic>>([
    dio.get<dynamic>('/v1/models'),
    dio.get<dynamic>('/v1/audio/voices'),
  ]);
  final models = responses[0].data;
  return GatewayCatalog(
    sttModels: _audioModels(models, 'stt'),
    ttsModels: _audioModels(models, 'tts'),
    voices: _voices(responses[1].data),
  );
});

List<GatewayAudioModel> _audioModels(dynamic body, String type) {
  final entries = body is Map ? body['data'] : null;
  if (entries is! List) return const <GatewayAudioModel>[];
  final models = <GatewayAudioModel>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    if (entry['type'] != type) continue;
    final id = entry['id'];
    if (id is! String || id.isEmpty) continue;
    final backend = entry['backend'];
    models.add(
      GatewayAudioModel(
        id: id,
        backend: backend is String && backend.isNotEmpty ? backend : id,
      ),
    );
  }
  return models;
}

List<String> _voices(dynamic body) {
  final entries = body is Map ? body['voices'] : null;
  if (entries is! List) return const <String>[];
  return <String>[
    for (final entry in entries)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}
