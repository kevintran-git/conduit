import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/inference_kit.dart' as ik;
import 'package:material_ui/material_ui.dart';

import '../../shared/widgets/adaptive_dropdown_field.dart';
import '../../shared/theme/theme_extensions.dart';
import '../config/gateway_catalog.dart';
import '../config/gateway_providers.dart';

class _GatewayChoiceField extends StatelessWidget {
  const _GatewayChoiceField({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
    this.serverDefaultLabel,
  });

  final String label;
  final String value;
  final List<({String value, String label})> values;
  final ValueChanged<String> onChanged;
  final String? serverDefaultLabel;

  @override
  Widget build(BuildContext context) {
    final defaultLabel = serverDefaultLabel;
    final options = <AdaptiveDropdownOption<String>>[
      if (defaultLabel != null)
        AdaptiveDropdownOption<String>(value: '', label: defaultLabel),
      for (final entry in values)
        AdaptiveDropdownOption<String>(value: entry.value, label: entry.label),
    ];
    if (!options.any((option) => option.value == value)) {
      options.add(AdaptiveDropdownOption<String>(value: value, label: value));
    }
    return AdaptiveDropdownField<String>(
      value: value,
      options: options,
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label),
      nativeTitle: label,
    );
  }
}

class GatewaySttModelField extends ConsumerWidget {
  const GatewaySttModelField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(gatewayConfigProvider);
    final catalog = ref.watch(gatewayCatalogProvider).asData?.value;
    final models = catalog?.sttModels ?? const <GatewayAudioModel>[];
    return _GatewayChoiceField(
      label: 'Transcription model',
      value: cfg.sttModel,
      serverDefaultLabel: 'Gateway default',
      values: [
        for (final model in models) (value: model.backend, label: model.id),
      ],
      onChanged: ref.read(gatewayConfigProvider.notifier).setSttModel,
    );
  }
}

class GatewayTtsOptions extends ConsumerWidget {
  const GatewayTtsOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(gatewayConfigProvider);
    final catalog = ref.watch(gatewayCatalogProvider).asData?.value;
    final notifier = ref.read(gatewayConfigProvider.notifier);
    final models = catalog?.ttsModels ?? const <GatewayAudioModel>[];
    final voices = catalog?.voices ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _GatewayChoiceField(
          label: 'Model',
          value: cfg.ttsModel,
          serverDefaultLabel: 'Gateway default',
          values: [
            for (final model in models) (value: model.id, label: model.id),
          ],
          onChanged: notifier.setTtsModel,
        ),
        const SizedBox(height: Spacing.md),
        _GatewayChoiceField(
          label: 'Voice',
          value: cfg.ttsVoice,
          serverDefaultLabel: 'Gateway default',
          values: [for (final voice in voices) (value: voice, label: voice)],
          onChanged: notifier.setTtsVoice,
        ),
      ],
    );
  }
}

class GatewayCallModelField extends ConsumerWidget {
  const GatewayCallModelField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(gatewayConfigProvider);
    final catalog = ref.watch(gatewayLiveCatalogProvider).asData?.value;
    final models = catalog?.models ?? const <ik.LiveModel>[];
    return _GatewayChoiceField(
      label: 'Live model',
      value: cfg.callModel,
      serverDefaultLabel: 'Gateway default',
      values: [for (final model in models) (value: model.id, label: model.id)],
      onChanged: ref.read(gatewayConfigProvider.notifier).setCallModel,
    );
  }
}

class GatewayCallVoiceField extends ConsumerWidget {
  const GatewayCallVoiceField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(gatewayConfigProvider);
    final voices = ref.watch(gatewayCatalogProvider).asData?.value.voices ??
        const <String>[];
    return _GatewayChoiceField(
      label: 'Live voice',
      value: cfg.callVoice,
      serverDefaultLabel: 'Gateway default',
      values: [for (final voice in voices) (value: voice, label: voice)],
      onChanged: ref.read(gatewayConfigProvider.notifier).setCallVoice,
    );
  }
}

class GatewayCallThinkingLevelField extends ConsumerWidget {
  const GatewayCallThinkingLevelField({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(gatewayConfigProvider);
    final catalog = ref.watch(gatewayLiveCatalogProvider).asData?.value;
    if (catalog == null || !catalog.supportsThinking(cfg.callModel)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: _GatewayChoiceField(
        label: 'Thinking level',
        value: cfg.callThinkingLevel,
        serverDefaultLabel: 'Model default',
        values: [
          for (final level in catalog.thinkingLevels)
            (value: level, label: level),
        ],
        onChanged: ref
            .read(gatewayConfigProvider.notifier)
            .setCallThinkingLevel,
      ),
    );
  }
}
