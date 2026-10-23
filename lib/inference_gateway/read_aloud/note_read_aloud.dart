import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/chat/providers/text_to_speech_provider.dart';
import '../../shared/widgets/adaptive_toolbar_components.dart';

const String _readAloudAction = 'gateway-read-aloud';

String _noteSpeechId(String? noteId) => 'note:${noteId ?? 'draft'}';

bool _isReading(TextToSpeechState state, String id) =>
    state.activeMessageId == id &&
    state.status != TtsPlaybackStatus.idle &&
    state.status != TtsPlaybackStatus.error;

List<AdaptivePopupMenuEntry> gatewayNoteMenuItems(
  WidgetRef ref, {
  required String? noteId,
}) {
  final id = _noteSpeechId(noteId);
  final reading = ref.watch(
    textToSpeechControllerProvider.select((s) => _isReading(s, id)),
  );
  return [
    AdaptivePopupMenuItem<String>(
      value: _readAloudAction,
      label: reading ? 'Stop reading' : 'Read aloud',
      icon: conduitAdaptivePopupMenuIcon(
        iosSymbol: reading ? 'speaker.slash' : 'speaker.wave.2',
        materialIcon: reading
            ? Icons.volume_off_outlined
            : Icons.volume_up_outlined,
      ),
    ),
  ];
}

void handleGatewayNoteMenuSelection(
  WidgetRef ref,
  String value, {
  required String? noteId,
  required String Function() markdown,
}) {
  if (value != _readAloudAction) return;
  final id = _noteSpeechId(noteId);
  final controller = ref.read(textToSpeechControllerProvider.notifier);
  if (_isReading(ref.read(textToSpeechControllerProvider), id)) {
    unawaited(controller.stop());
    return;
  }
  unawaited(controller.toggleForMessage(messageId: id, text: markdown()));
}
