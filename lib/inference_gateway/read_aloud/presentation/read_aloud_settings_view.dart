import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:inference_kit/read_aloud.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../settings/gateway_model_pickers.dart';
import '../read_aloud_settings_provider.dart';

String readAloudSkipLabel(InlineSkipKind kind) => switch (kind) {
  InlineSkipKind.url => 'Links',
  InlineSkipKind.citation => 'Citations',
  InlineSkipKind.bracketed => 'Text in [brackets]',
  InlineSkipKind.braced => 'Text in {braces}',
  InlineSkipKind.parenthesized => 'Text in (parentheses)',
};

class ReadAloudSettingsView extends ConsumerWidget {
  const ReadAloudSettingsView({super.key, this.showVoice = true});

  final bool showVoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readAloudSettingsProvider);
    final notifier = ref.read(readAloudSettingsProvider.notifier);
    const ramp = ReadAloudSettings.ramp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showVoice) ...[
          const GatewayTtsOptions(),
          const SizedBox(height: Spacing.md),
        ],
        _TextSetting(
          label: 'Speaking style',
          hint: 'How the voice should sound',
          initial: settings.style,
          onChanged: (value) =>
              notifier.change((s) => s.copyWith(style: value)),
        ),
        const SizedBox(height: Spacing.md),
        _WordsPerRequest(
          value: settings.wordsPerRequest,
          onChanged: (value) =>
              notifier.change((s) => s.copyWith(wordsPerRequest: value)),
        ),
        const SizedBox(height: Spacing.sm),
        _SwitchRow(
          title: 'Highlight words',
          value: settings.highlightWords,
          onChanged: (on) =>
              notifier.change((s) => s.copyWith(highlightWords: on)),
        ),
        _SwitchRow(
          title: 'Follow the voice',
          subtitle: 'Keep the spoken line in view',
          value: settings.followVoice,
          onChanged: (on) =>
              notifier.change((s) => s.copyWith(followVoice: on)),
        ),
        _SwitchRow(
          title: 'Auto speed-up',
          subtitle:
              'Adds ${ramp.step}× every ${ramp.everyWords} words, '
              'up to ${ramp.max}×',
          value: settings.autoSpeed,
          onChanged: (on) => notifier.change((s) => s.copyWith(autoSpeed: on)),
        ),
        const SizedBox(height: Spacing.md),
        _Heading('Skip while reading'),
        for (final kind in InlineSkipKind.values)
          _SwitchRow(
            title: readAloudSkipLabel(kind),
            value: settings.skip.contains(kind),
            onChanged: (on) => notifier.change((s) => s.withSkip(kind, on)),
          ),
        const SizedBox(height: Spacing.md),
        _TextSetting(
          label: 'Pronunciations',
          hint: 'One word=spoken form per line',
          initial: settings.pronunciations,
          multiline: true,
          onChanged: (value) =>
              notifier.change((s) => s.copyWith(pronunciations: value)),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xs),
      child: Text(
        text,
        style: theme.bodySmall?.copyWith(
          color: theme.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final detail = subtitle;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.bodySmall?.copyWith(
                        color: theme.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            AdaptiveSwitch(
              value: value,
              onChanged: onChanged,
              semanticLabel: title,
            ),
          ],
        ),
      ),
    );
  }
}

class _WordsPerRequest extends StatefulWidget {
  const _WordsPerRequest({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_WordsPerRequest> createState() => _WordsPerRequestState();
}

class _WordsPerRequestState extends State<_WordsPerRequest> {
  static const int _step = 20;

  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    const min = ReadAloudSettings.minWordsPerRequest;
    const max = ReadAloudSettings.maxWordsPerRequest;
    final value = _dragging ?? widget.value.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Up to ${value.round()} words per request',
          style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
        ),
        Text(
          'Fewer starts sooner. More keeps a paragraph in one steady take.',
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        Slider.adaptive(
          value: value.clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: (max - min) ~/ _step,
          label: '${value.round()}',
          onChanged: (next) => setState(() => _dragging = next),
          onChangeEnd: (next) {
            setState(() => _dragging = null);
            widget.onChanged(next.round());
          },
        ),
      ],
    );
  }
}

class _TextSetting extends StatefulWidget {
  const _TextSetting({
    required this.label,
    required this.hint,
    required this.initial,
    required this.onChanged,
    this.multiline = false,
  });

  final String label;
  final String hint;
  final String initial;
  final ValueChanged<String> onChanged;
  final bool multiline;

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConduitInput(
      label: widget.label,
      hint: widget.hint,
      controller: _controller,
      minLines: widget.multiline ? 2 : 1,
      maxLines: widget.multiline ? 6 : 2,
      keyboardType: widget.multiline
          ? TextInputType.multiline
          : TextInputType.text,
      onChanged: widget.onChanged,
    );
  }
}
