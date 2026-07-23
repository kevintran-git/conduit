import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/navigation_service.dart';
import '../../core/services/settings_service.dart';
import '../../features/profile/widgets/adaptive_segmented_selector.dart';
import '../../features/profile/widgets/customization_tile.dart';
import '../../features/profile/widgets/expandable_card.dart';
import '../../features/profile/widgets/profile_setting_tile.dart';
import '../../features/profile/widgets/settings_page_scaffold.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/utils/ui_utils.dart';
import '../../shared/widgets/conduit_components.dart';
import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';
import 'realtime_tuning_card.dart';

enum _CallMode { conduit, pipeline, realtime }

typedef _Gate = ({bool inactive, String? reason});

const _Gate _active = (inactive: false, reason: null);
const _Gate _silentGate = (inactive: true, reason: null);

_Gate _reasonGate(String reason) => (inactive: true, reason: reason);

class GatewaySettingsPage extends ConsumerStatefulWidget {
  const GatewaySettingsPage({super.key});

  @override
  ConsumerState<GatewaySettingsPage> createState() =>
      _GatewaySettingsPageState();
}

class _GatewaySettingsPageState extends ConsumerState<GatewaySettingsPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  late final TextEditingController _ttsModelController;
  late final TextEditingController _ttsVoiceController;
  late final TextEditingController _callSystemPromptController;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(gatewayConfigProvider);
    _urlController = TextEditingController(text: cfg.baseUrl);
    _keyController = TextEditingController(text: cfg.apiKey);
    _ttsModelController = TextEditingController(text: cfg.ttsModel);
    _ttsVoiceController = TextEditingController(text: cfg.ttsVoice);
    _callSystemPromptController = TextEditingController(
      text: cfg.callSystemPrompt ?? '',
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _ttsModelController.dispose();
    _ttsVoiceController.dispose();
    _callSystemPromptController.dispose();
    super.dispose();
  }

  void _hydrateIfEmpty(TextEditingController controller, String value) {
    if (controller.text.isNotEmpty) return;
    if (controller.text == value) return;
    controller.text = value;
  }

  static const String _addKeyReason = 'Add key above to activate.';

  _Gate _credentialsGate(GatewayConfig cfg) =>
      cfg.hasCredentials ? _active : _silentGate;

  _Gate _sttGate(GatewayConfig cfg, AppSettings settings) {
    final base = _credentialsGate(cfg);
    if (base.inactive) return base;
    if (settings.sttPreference != SttPreference.serverOnly) {
      return _reasonGate('Inactive — Audio input set to on-device.');
    }
    return _active;
  }

  _Gate _ttsToggleGate(GatewayConfig cfg, AppSettings settings) {
    final base = _credentialsGate(cfg);
    if (base.inactive) return base;
    if (settings.ttsEngine != TtsEngine.server) {
      return _reasonGate('Inactive — Audio output set to on-device.');
    }
    return _active;
  }

  _Gate _voiceGate(GatewayConfig cfg) => _credentialsGate(cfg);

  _CallMode _callModeOf(GatewayConfig cfg) {
    if (cfg.realtimeEnabled) return _CallMode.realtime;
    if (cfg.voiceEnabled) return _CallMode.pipeline;
    return _CallMode.conduit;
  }

  Future<void> _setCallMode(
    GatewayConfigNotifier notifier,
    _CallMode mode,
  ) async {
    switch (mode) {
      case _CallMode.conduit:
        await notifier.setRealtimeEnabled(false);
        await notifier.setVoiceEnabled(false);
      case _CallMode.pipeline:
        await notifier.setRealtimeEnabled(false);
        await notifier.setVoiceEnabled(true);
      case _CallMode.realtime:
        await notifier.setRealtimeEnabled(true);
    }
  }

  String _callModeDescription(_CallMode mode) {
    switch (mode) {
      case _CallMode.conduit:
        return "Built-in call, routed through Open WebUI.";
      case _CallMode.pipeline:
        return 'Turn-based: STT, chat, TTS — via the gateway.';
      case _CallMode.realtime:
        return 'Live audio stream via Gemini Live, no pipeline.';
    }
  }

  _Gate _callSystemPromptGate(GatewayConfig cfg) {
    final base = _voiceGate(cfg);
    if (base.inactive) return base;
    if (_callModeOf(cfg) == _CallMode.conduit) {
      return _reasonGate('Inactive — Call mode is Conduit.');
    }
    return _active;
  }

  _Gate _toolsGate(GatewayConfig cfg) {
    final base = _credentialsGate(cfg);
    if (base.inactive) return base;
    if (!cfg.voiceEnabled && !cfg.realtimeEnabled) {
      return _reasonGate('Inactive — enable a call mode below.');
    }
    return _active;
  }

  _Gate _ttsDefaultsGate(GatewayConfig cfg, AppSettings settings) {
    final base = _ttsToggleGate(cfg, settings);
    if (base.inactive) return base;
    if (!cfg.ttsEnabled) {
      return _reasonGate('Inactive — enable Text-to-speech above.');
    }
    return _active;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GatewayConfig>(gatewayConfigProvider, (previous, next) {
      _hydrateIfEmpty(_urlController, next.baseUrl);
      _hydrateIfEmpty(_keyController, next.apiKey);
      _hydrateIfEmpty(_ttsModelController, next.ttsModel);
      _hydrateIfEmpty(_ttsVoiceController, next.ttsVoice);
      _hydrateIfEmpty(_callSystemPromptController, next.callSystemPrompt ?? '');
    });
    final cfg = ref.watch(gatewayConfigProvider);
    final settings = ref.watch(appSettingsProvider);
    final theme = context.conduitTheme;
    final notifier = ref.read(gatewayConfigProvider.notifier);

    final hasCustomPrompt = (cfg.callSystemPrompt ?? '').trim().isNotEmpty;

    return SettingsPageScaffold(
      title: 'Inference Gateway',
      children: [
        _buildIntro(context),
        settingsSectionGap,
        _buildEndpointSection(context, cfg, notifier, theme),
        settingsSectionGap,
        SettingsSectionHeader(title: 'Gateway features'),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.mic_none,
          title: 'Speech-to-text',
          subtitle: 'Gateway transcribes your mic input.',
          value: cfg.sttEnabled,
          onChanged: notifier.setSttEnabled,
          gate: _sttGate(cfg, settings),
          onInactiveAction: () => context.pushNamed(RouteNames.audioSettings),
          inactiveActionLabel: 'Audio settings',
        ),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.volume_up_outlined,
          title: 'Text-to-speech',
          subtitle: 'Gateway reads replies aloud.',
          value: cfg.ttsEnabled,
          onChanged: notifier.setTtsEnabled,
          gate: _ttsToggleGate(cfg, settings),
          onInactiveAction: () => context.pushNamed(RouteNames.audioSettings),
          inactiveActionLabel: 'Audio settings',
        ),
        const SizedBox(height: Spacing.sm),
        _wrapInactive(
          context,
          ExpandableCard(
            title: 'Voice options',
            subtitle: '${cfg.ttsModel} · ${cfg.ttsVoice}',
            icon: Icons.record_voice_over_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConduitInput(
                  label: 'TTS model',
                  hint: GatewayConfig.defaultTtsModel,
                  controller: _ttsModelController,
                  textInputAction: TextInputAction.next,
                  onSubmitted: notifier.setTtsModel,
                ),
                const SizedBox(height: Spacing.md),
                ConduitInput(
                  label: 'TTS voice',
                  hint: GatewayConfig.defaultTtsVoice,
                  controller: _ttsVoiceController,
                  textInputAction: TextInputAction.done,
                  onSubmitted: notifier.setTtsVoice,
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: ConduitButton(
                        text: 'Save',
                        onPressed: () async {
                          await notifier.setTtsModel(_ttsModelController.text);
                          await notifier.setTtsVoice(_ttsVoiceController.text);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _ttsDefaultsGate(cfg, settings),
        ),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.query_stats,
          title: 'Chat usage stats tool',
          subtitle: 'Model can check your usage stats.',
          value: cfg.statsToolEnabled,
          onChanged: notifier.setStatsToolEnabled,
          gate: _toolsGate(cfg),
        ),
        settingsSectionGap,
        SettingsSectionHeader(title: 'Voice call'),
        const SizedBox(height: Spacing.sm),
        _wrapInactive(
          context,
          ConduitCard(
            child: Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AdaptiveSegmentedSelector<_CallMode>(
                    value: _callModeOf(cfg),
                    onChanged: (mode) => _setCallMode(notifier, mode),
                    options: const [
                      (
                        value: _CallMode.conduit,
                        label: 'Conduit',
                        cupertinoIcon: CupertinoIcons.app,
                        materialIcon: Icons.apps,
                        enabled: true,
                      ),
                      (
                        value: _CallMode.pipeline,
                        label: 'Pipeline',
                        cupertinoIcon: CupertinoIcons.phone,
                        materialIcon: Icons.call,
                        enabled: true,
                      ),
                      (
                        value: _CallMode.realtime,
                        label: 'Realtime',
                        cupertinoIcon: CupertinoIcons.waveform,
                        materialIcon: Icons.graphic_eq,
                        enabled: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    _callModeDescription(_callModeOf(cfg)),
                    style: theme.bodySmall?.copyWith(
                      color: theme.sidebarForeground.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _voiceGate(cfg),
        ),
        if (cfg.realtimeEnabled) ...[
          const SizedBox(height: Spacing.sm),
          const RealtimeTuningCard(),
        ],
        const SizedBox(height: Spacing.sm),
        _wrapInactive(
          context,
          ExpandableCard(
            title: 'Call system prompt',
            subtitle: hasCustomPrompt
                ? 'Custom · tap to edit'
                : 'Using model default · tap to customize',
            icon: Icons.forum_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Used when the server sends no system prompt.',
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                ConduitInput(
                  controller: _callSystemPromptController,
                  hint:
                      'You are a helpful voice assistant. Reply in plain '
                      'conversational sentences. Be concise — no bullet points, '
                      'no markdown, no code blocks.',
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: ConduitButton(
                        text: 'Save',
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          await notifier.setCallSystemPrompt(
                            _callSystemPromptController.text,
                          );
                          messenger?.showSnackBar(
                            const SnackBar(
                              content: Text('Call system prompt saved'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _callSystemPromptGate(cfg),
        ),
      ],
    );
  }

  Widget _buildEndpointSection(
    BuildContext context,
    GatewayConfig cfg,
    GatewayConfigNotifier notifier,
    ConduitThemeExtension theme,
  ) {
    final form = _buildEndpointForm(context, cfg, notifier, theme);
    final subtitle = GatewayConfig.hasEnvCredentials
        ? 'Set via environment · tap to edit'
        : cfg.hasCredentials
        ? 'Configured · tap to edit'
        : 'Not configured · tap to add a key';
    return ExpandableCard(
      title: 'Endpoint',
      subtitle: subtitle,
      icon: Icons.dns_outlined,
      child: form,
    );
  }

  Widget _buildEndpointForm(
    BuildContext context,
    GatewayConfig cfg,
    GatewayConfigNotifier notifier,
    ConduitThemeExtension theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConduitInput(
          label: 'Base URL',
          hint: GatewayConfig.defaultBaseUrl,
          controller: _urlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          onSubmitted: (value) => notifier.setBaseUrl(value),
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          label: 'API key',
          hint: 'sk-...',
          controller: _keyController,
          obscureText: _obscureKey,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => notifier.setApiKey(value),
          suffixIcon: IconButton(
            icon: Icon(
              _obscureKey
                  ? UiUtils.platformIcon(
                      ios: CupertinoIcons.eye,
                      android: Icons.visibility,
                    )
                  : UiUtils.platformIcon(
                      ios: CupertinoIcons.eye_slash,
                      android: Icons.visibility_off,
                    ),
              color: theme.iconSecondary,
              size: IconSize.medium,
            ),
            onPressed: () => setState(() => _obscureKey = !_obscureKey),
          ),
        ),
        const SizedBox(height: Spacing.md),
        Row(
          children: [
            Expanded(
              child: ConduitButton(
                text: 'Save endpoint',
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await notifier.setBaseUrl(_urlController.text);
                  await notifier.setApiKey(_keyController.text);
                  if (!mounted || messenger == null) return;
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Gateway settings saved'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        if (!cfg.hasCredentials) ...[
          const SizedBox(height: Spacing.sm),
          Text(
            _addKeyReason,
            style: theme.bodySmall?.copyWith(color: theme.warning),
          ),
        ],
      ],
    );
  }

  Widget _buildIntro(BuildContext context) {
    final cfg = ref.watch(gatewayConfigProvider);
    return ConduitCard(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StatusLine(
              label: 'Credentials',
              value: cfg.hasCredentials ? 'OK' : 'Missing API key',
              ok: cfg.hasCredentials,
            ),
          ],
        ),
      ),
    );
  }

  Widget _wrapInactive(BuildContext context, Widget child, _Gate gate) {
    if (!gate.inactive) return child;
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(opacity: 0.5, child: IgnorePointer(child: child)),
        if (gate.reason != null)
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: IconSize.small,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    gate.reason!,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildToggleTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
    _Gate gate = _active,
    VoidCallback? onInactiveAction,
    String? inactiveActionLabel,
  }) {
    final theme = context.conduitTheme;
    final tile = CustomizationTile(
      leading: SettingsIconBadge(icon: icon, color: theme.buttonPrimary),
      title: title,
      subtitle: subtitle,
      trailing: AdaptiveSwitch(value: value, onChanged: onChanged),
      showChevron: false,
      onTap: () => onChanged(!value),
    );
    if (!gate.inactive) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Opacity(opacity: 0.5, child: tile),
        if (gate.reason != null)
          Padding(
            padding: const EdgeInsets.only(left: Spacing.md, top: Spacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: IconSize.small,
                  color: theme.textSecondary,
                ),
                const SizedBox(width: Spacing.xs),
                Expanded(
                  child: Text(
                    gate.reason!,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ),
                if (onInactiveAction != null && inactiveActionLabel != null)
                  TextButton(
                    onPressed: onInactiveAction,
                    child: Text(inactiveActionLabel),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = ok ? theme.success : theme.warning;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.warning_amber_rounded,
            size: IconSize.small,
            color: color,
          ),
          const SizedBox(width: Spacing.xs),
          Text(
            '$label: ',
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
          Expanded(
            child: Text(value, style: theme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

Widget gatewayProfileTile(BuildContext context) {
  final theme = context.conduitTheme;
  final color = theme.buttonPrimary;
  return ProfileSettingTile(
    onTap: () => context.pushNamed('gateway-settings'),
    leading: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.bolt_horizontal_circle,
          android: Icons.bolt,
        ),
        color: color,
        size: IconSize.medium,
      ),
    ),
    title: 'Inference Gateway',
    subtitle: 'Route STT, chat, and TTS to your own endpoint',
    trailing: Icon(
      UiUtils.platformIcon(
        ios: CupertinoIcons.chevron_right,
        android: Icons.chevron_right,
      ),
      color: theme.iconSecondary,
      size: IconSize.small,
    ),
  );
}
