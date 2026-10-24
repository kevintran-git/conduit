import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/services/navigation_service.dart';

import '../../features/profile/widgets/expandable_card.dart';
import '../../features/profile/widgets/profile_setting_tile.dart';
import '../../features/profile/widgets/settings_page_scaffold.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/utils/ui_utils.dart';
import '../../shared/widgets/conduit_components.dart';
import '../../shared/widgets/utility_components.dart';
import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';
import '../read_aloud/presentation/read_aloud_settings_view.dart';
import '../voice_call/presentation/gateway_call_launcher.dart';

class GatewaySettingsPage extends ConsumerStatefulWidget {
  const GatewaySettingsPage({super.key});

  @override
  ConsumerState<GatewaySettingsPage> createState() =>
      _GatewaySettingsPageState();
}

class _GatewaySettingsPageState extends ConsumerState<GatewaySettingsPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _keyController;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(gatewayConfigProvider);
    _urlController = TextEditingController(text: cfg.baseUrl);
    _keyController = TextEditingController(text: cfg.apiKey);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _hydrateIfEmpty(TextEditingController controller, String value) {
    if (controller.text.isNotEmpty) return;
    if (controller.text == value) return;
    controller.text = value;
  }

  static const String _addKeyReason = 'Add key above to activate.';

  @override
  Widget build(BuildContext context) {
    ref.listen<GatewayConfig>(gatewayConfigProvider, (previous, next) {
      _hydrateIfEmpty(_urlController, next.baseUrl);
      _hydrateIfEmpty(_keyController, next.apiKey);
    });
    final cfg = ref.watch(gatewayConfigProvider);
    final theme = context.conduitTheme;
    final notifier = ref.read(gatewayConfigProvider.notifier);

    return UtilityPageScaffold.settings(
      title: 'Inference Gateway',
      children: [
        _buildEndpointSection(context, cfg, notifier, theme),
        if (cfg.hasCredentials) ...[
          settingsSectionGap,
          SettingsSectionHeader(title: 'Routing'),
          const SizedBox(height: Spacing.sm),
          _buildRouting(context, cfg),
          settingsSectionGap,
          SettingsSectionHeader(title: 'Read aloud'),
          const SizedBox(height: Spacing.sm),
          ConduitCard(
            child: const Padding(
              padding: EdgeInsets.all(Spacing.md),
              child: ReadAloudSettingsView(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRouting(BuildContext context, GatewayConfig cfg) {
    final tts = ref.watch(gatewayTtsActiveProvider);
    final stt = ref.watch(gatewaySttActiveProvider);
    final realtime = ref.watch(gatewayCallsUseRealtimeProvider).asData?.value;
    void openAudio() => context.pushNamed(RouteNames.audioSettings);
    final voice = cfg.ttsVoice.isEmpty ? 'default voice' : cfg.ttsVoice;
    return ConduitCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
        child: Column(
          children: [
            _RouteRow(
              icon: Icons.volume_up_outlined,
              title: 'Read aloud and replies',
              value: tts ? 'Gateway, $voice' : 'Device voice',
              onTap: openAudio,
            ),
            _RouteRow(
              icon: Icons.mic_none,
              title: 'Dictation',
              value: stt ? 'Gateway transcription' : 'On-device',
              onTap: openAudio,
            ),
            _RouteRow(
              icon: Icons.call_outlined,
              title: 'Calls',
              value: switch (realtime) {
                null => 'Checking…',
                true => 'Open WebUI live voice',
                false => 'Gateway, turn by turn',
              },
              onTap: openAudio,
            ),
          ],
        ),
      ),
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
        ? 'Set via environment'
        : cfg.hasCredentials
        ? 'Configured'
        : 'Add a key';
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
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, size: IconSize.medium, color: theme.iconSecondary),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
                  ),
                  Text(
                    value,
                    style: theme.bodySmall?.copyWith(
                      color: theme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.chevron_right,
                android: Icons.chevron_right,
              ),
              size: IconSize.small,
              color: theme.iconSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

Widget gatewayProfileTile(BuildContext context) {
  final theme = context.conduitTheme;
  final color = theme.buttonPrimary;
  return ProfileSettingTile(
    onTap: () => Navigator.of(context).push<void>(
      Theme.of(context).platform == TargetPlatform.iOS
          ? CupertinoPageRoute<void>(
              builder: (_) => const GatewaySettingsPage(),
            )
          : MaterialPageRoute<void>(
              builder: (_) => const GatewaySettingsPage(),
            ),
    ),
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
    subtitle: 'Read aloud, voices and calls through your endpoint',
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
