import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/profile/widgets/adaptive_segmented_selector.dart';
import '../../features/profile/widgets/expandable_card.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/widgets/conduit_components.dart';
import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';

class RealtimeTuningCard extends ConsumerStatefulWidget {
  const RealtimeTuningCard({super.key});

  @override
  ConsumerState<RealtimeTuningCard> createState() =>
      _RealtimeTuningCardState();
}

class _RealtimeTuningCardState extends ConsumerState<RealtimeTuningCard> {
  late final TextEditingController _callModelController;
  late final TextEditingController _callVoiceController;
  late final TextEditingController _callPauseToleranceController;
  late final TextEditingController _callPrefixPaddingController;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(gatewayConfigProvider);
    _callModelController = TextEditingController(text: cfg.callModel);
    _callVoiceController = TextEditingController(text: cfg.callVoice);
    _callPauseToleranceController = TextEditingController(
      text: cfg.callPauseToleranceMs.toString(),
    );
    _callPrefixPaddingController = TextEditingController(
      text: cfg.callPrefixPaddingMs.toString(),
    );
  }

  @override
  void dispose() {
    _callModelController.dispose();
    _callVoiceController.dispose();
    _callPauseToleranceController.dispose();
    _callPrefixPaddingController.dispose();
    super.dispose();
  }

  void _hydrateIfEmpty(TextEditingController controller, String value) {
    if (controller.text.isNotEmpty) return;
    if (controller.text == value) return;
    controller.text = value;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GatewayConfig>(gatewayConfigProvider, (previous, next) {
      _hydrateIfEmpty(_callModelController, next.callModel);
      _hydrateIfEmpty(_callVoiceController, next.callVoice);
      _hydrateIfEmpty(
        _callPauseToleranceController,
        next.callPauseToleranceMs.toString(),
      );
      _hydrateIfEmpty(
        _callPrefixPaddingController,
        next.callPrefixPaddingMs.toString(),
      );
    });
    final cfg = ref.watch(gatewayConfigProvider);
    final notifier = ref.read(gatewayConfigProvider.notifier);

    return ExpandableCard(
      title: 'Realtime tuning',
      subtitle: '${cfg.callModel} · ${cfg.callVoice}',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConduitInput(
            label: 'Live model',
            hint: GatewayConfig.defaultCallModel,
            controller: _callModelController,
            textInputAction: TextInputAction.next,
            onSubmitted: notifier.setCallModel,
          ),
          const SizedBox(height: Spacing.md),
          ConduitInput(
            label: 'Live voice',
            hint: GatewayConfig.defaultCallVoice,
            controller: _callVoiceController,
            textInputAction: TextInputAction.next,
            onSubmitted: notifier.setCallVoice,
          ),
          const SizedBox(height: Spacing.md),
          ConduitInput(
            label: 'Pause tolerance (ms)',
            hint: '${GatewayConfig.defaultCallPauseToleranceMs}',
            controller: _callPauseToleranceController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            onSubmitted: (value) => notifier.setCallPauseToleranceMs(
              int.tryParse(value.trim()) ??
                  GatewayConfig.defaultCallPauseToleranceMs,
            ),
          ),
          const SizedBox(height: Spacing.md),
          ConduitInput(
            label: 'Prefix padding (ms)',
            hint: '${GatewayConfig.defaultCallPrefixPaddingMs}',
            controller: _callPrefixPaddingController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onSubmitted: (value) => notifier.setCallPrefixPaddingMs(
              int.tryParse(value.trim()) ??
                  GatewayConfig.defaultCallPrefixPaddingMs,
            ),
          ),
          const SizedBox(height: Spacing.md),
          _SensitivityRow(
            label: 'Start-of-speech sensitivity',
            value: cfg.callStartSensitivity,
            onChanged: notifier.setCallStartSensitivity,
          ),
          const SizedBox(height: Spacing.md),
          _SensitivityRow(
            label: 'End-of-speech sensitivity',
            value: cfg.callEndSensitivity,
            onChanged: notifier.setCallEndSensitivity,
          ),
        ],
      ),
    );
  }
}

class _SensitivityRow extends StatelessWidget {
  const _SensitivityRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Future<void> Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.bodyMedium?.copyWith(
            color: theme.sidebarForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        AdaptiveSegmentedSelector<String>(
          value: value,
          onChanged: onChanged,
          options: const [
            (
              value: 'LOW',
              label: 'Low',
              cupertinoIcon: CupertinoIcons.arrow_down,
              materialIcon: Icons.arrow_downward,
              enabled: true,
            ),
            (
              value: 'HIGH',
              label: 'High',
              cupertinoIcon: CupertinoIcons.arrow_up,
              materialIcon: Icons.arrow_upward,
              enabled: true,
            ),
          ],
        ),
      ],
    );
  }
}
