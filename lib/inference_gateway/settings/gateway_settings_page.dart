import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/profile/widgets/customization_tile.dart';
import '../../features/profile/widgets/profile_setting_tile.dart';
import '../../features/profile/widgets/settings_page_scaffold.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/utils/ui_utils.dart';
import '../../shared/widgets/conduit_components.dart';
import '../config/gateway_config.dart';
import '../config/gateway_providers.dart';

/// Settings UI for the inference gateway shim.
///
/// Lets the user point inference at their own OpenAI-compatible endpoint
/// (default `api.kvt.codes`) and toggle which services route there. With
/// everything off, the app falls back to OWUI verbatim.
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

  /// Only hydrate an empty field. If the user has typed anything, the
  /// async API-key hydration must not overwrite it; the page is the only
  /// thing that mutates these fields, so once non-empty they're authoritative.
  void _hydrateIfEmpty(TextEditingController controller, String value) {
    if (controller.text.isNotEmpty) return;
    if (controller.text == value) return;
    controller.text = value;
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
    final theme = context.conduitTheme;
    final notifier = ref.read(gatewayConfigProvider.notifier);

    return SettingsPageScaffold(
      title: 'Inference Gateway',
      children: [
        _buildIntro(context),
        settingsSectionGap,
        SettingsSectionHeader(title: 'Endpoint'),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
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
                    onPressed: () =>
                        setState(() => _obscureKey = !_obscureKey),
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
                    'Add an API key to activate any toggle below.',
                    style: theme.bodySmall?.copyWith(color: theme.warning),
                  ),
                ],
              ],
            ),
          ),
        ),
        settingsSectionGap,
        SettingsSectionHeader(title: 'Route through gateway'),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.chat_bubble_outline,
          title: 'Chat completions',
          subtitle:
              'Send LLM requests to the gateway instead of Open WebUI. Models load from /v1/models.',
          value: cfg.chatEnabled,
          onChanged: notifier.setChatEnabled,
        ),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.mic_none,
          title: 'Speech-to-text',
          subtitle:
              'Mic taps in chat upload to the gateway. On-device STT is unaffected.',
          value: cfg.sttEnabled,
          onChanged: notifier.setSttEnabled,
        ),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.volume_up_outlined,
          title: 'Text-to-speech',
          subtitle:
              'Speaker icon on assistant messages synthesizes via the gateway.',
          value: cfg.ttsEnabled,
          onChanged: notifier.setTtsEnabled,
        ),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.call,
          title: 'Voice call (zero-wait pipeline)',
          subtitle:
              'Use WebSocket STT + streaming chat + ElevenLabs-style TTS for the calling screen.',
          value: cfg.voiceEnabled,
          onChanged: notifier.setVoiceEnabled,
        ),
        settingsSectionGap,
        SettingsSectionHeader(title: 'TTS defaults'),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
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
                        text: 'Save TTS defaults',
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
        ),
        settingsSectionGap,
        SettingsSectionHeader(title: 'Voice call mode'),
        const SizedBox(height: Spacing.sm),
        _buildToggleTile(
          context: context,
          icon: Icons.touch_app,
          title: 'Manual push-to-talk',
          subtitle:
              'Disable VAD entirely. Hold the screen to record, release to send. Off = VAD with press-to-suppress override.',
          value: cfg.voiceManualMode,
          onChanged: notifier.setVoiceManualMode,
        ),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Call system prompt',
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'Injected at the start of every call turn when the server has not provided a system prompt. Use it to keep replies short, remove markdown, etc. Leave blank to use the model\'s defaults.',
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                ConduitInput(
                  controller: _callSystemPromptController,
                  hint: 'You are a helpful voice assistant. Reply in plain '
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
                          await notifier.setCallSystemPrompt(
                            _callSystemPromptController.text,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
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
        ),
      ],
    );
  }

  Widget _buildIntro(BuildContext context) {
    final theme = context.conduitTheme;
    final cfg = ref.watch(gatewayConfigProvider);
    final chatActive = ref.watch(gatewayChatActiveProvider);
    return ConduitCard(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bypass Open WebUI for inference',
              style: theme.bodyMedium?.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Route STT, chat and TTS phone-to-gateway directly. Open WebUI keeps syncing your conversation history; everything else uses your own endpoint.',
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
            const SizedBox(height: Spacing.sm),
            _StatusLine(
              label: 'Credentials',
              value: cfg.hasCredentials ? 'OK' : 'Missing API key',
              ok: cfg.hasCredentials,
            ),
            _StatusLine(
              label: 'Chat routing active',
              value: chatActive ? 'Yes — sending to gateway' : 'No — falling back to OWUI',
              ok: chatActive,
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Heads-up: Conduit\'s own STT/TTS settings still pick "device" vs "server". When set to device, the gateway STT/TTS toggle does nothing (no API call is made). For chat-mic and speaker-icon to use the gateway, set Conduit\'s STT/TTS pref to "server".',
              style: theme.bodySmall?.copyWith(
                color: theme.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToggleTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    final theme = context.conduitTheme;
    return CustomizationTile(
      leading: SettingsIconBadge(icon: icon, color: theme.buttonPrimary),
      title: title,
      subtitle: subtitle,
      trailing: AdaptiveSwitch(value: value, onChanged: onChanged),
      showChevron: false,
      onTap: () => onChanged(!value),
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
            child: Text(
              value,
              style: theme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings-list entry that opens [GatewaySettingsPage].
///
/// Defined here, rather than inline in the upstream profile page, so that
/// `profile_page.dart` stays a single-line hook and rarely conflicts when
/// rebasing onto upstream. Styling mirrors the page's other account tiles.
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
