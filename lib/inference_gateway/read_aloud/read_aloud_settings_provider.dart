import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/read_aloud.dart';

import 'package:conduit_core/persistence/preferences_store.dart';

import '../config/gateway_providers.dart';

class ReadAloudSettingsNotifier extends Notifier<ReadAloudSettings> {
  static const String _key = 'gateway.read_aloud_settings';

  @override
  ReadAloudSettings build() {
    final raw = PreferencesStore.get<String>(_key);
    if (raw != null) {
      try {
        return ReadAloudSettings.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
      } on FormatException {
        return const ReadAloudSettings();
      }
    }
    final legacy = ref.read(gatewayStorageProvider).takeLegacyPronunciations();
    final settings = ReadAloudSettings(pronunciations: legacy);
    if (legacy.isNotEmpty) _save(settings);
    return settings;
  }

  void _save(ReadAloudSettings settings) {
    PreferencesStore.put(_key, jsonEncode(settings.toJson()));
  }

  void change(ReadAloudSettings Function(ReadAloudSettings) update) {
    final next = update(state);
    if (next == state) return;
    state = next;
    _save(next);
  }
}

final readAloudSettingsProvider =
    NotifierProvider<ReadAloudSettingsNotifier, ReadAloudSettings>(
      ReadAloudSettingsNotifier.new,
    );
