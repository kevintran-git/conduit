import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/inference_gateway/config/gateway_config.dart';
import 'package:conduit/inference_gateway/config/gateway_providers.dart';
import 'package:conduit/inference_gateway/settings/gateway_model_pickers.dart';
import 'package:conduit/inference_gateway/transport/gateway_client.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _FixedGatewayConfigNotifier extends GatewayConfigNotifier {
  _FixedGatewayConfigNotifier(this._config);
  final GatewayConfig _config;

  @override
  GatewayConfig build() => _config;
}

class _CatalogAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final payload = switch (options.path) {
      '/v1/models' => <String, Object?>{
        'data': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'eleven_v3',
            'type': 'tts',
            'backend': 'elevenlabs',
          },
          <String, Object?>{
            'id': 'chirp-3',
            'type': 'stt',
            'backend': 'google_chirp3',
          },
        ],
      },
      '/v1/audio/voices' => <String, Object?>{
        'voices': <String>['Rachel'],
      },
      _ => <String, Object?>{},
    };
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }
}

void main() {
  testWidgets(
    'TTS model picker uses catalog id while STT model picker uses backend',
    (tester) async {
      final config = GatewayConfig.defaults().copyWith(
        baseUrl: 'https://gateway.test',
        apiKey: 'secret-key',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            gatewayConfigProvider.overrideWith(
              () => _FixedGatewayConfigNotifier(config),
            ),
            gatewayClientProvider.overrideWith((ref) {
              final client = GatewayClient(ref: ref);
              client.dio.httpClientAdapter = _CatalogAdapter();
              return client;
            }),
          ],
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: const Scaffold(
              body: Column(
                children: [GatewayTtsOptions(), GatewaySttModelField()],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dropdowns = tester
          .widgetList<AdaptiveDropdownField<String>>(
            find.byType(AdaptiveDropdownField<String>),
          )
          .toList();

      final ttsModelValues = dropdowns[0].options.map((o) => o.value).toList();
      final sttModelValues = dropdowns[2].options.map((o) => o.value).toList();

      check(ttsModelValues).deepEquals(<String>['', 'eleven_v3']);
      check(sttModelValues).deepEquals(<String>['', 'google_chirp3']);
    },
  );
}
