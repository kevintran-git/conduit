import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/connectivity_service.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/widgets/themed_sheets.dart';
import '../config/gateway_providers.dart';
import '../sync/owui_mirror_providers.dart';

/// Wraps the routed body so that whenever OWUI is unreachable but the gateway
/// can still carry chat, a slim non-blocking banner appears at the top of the
/// screen explaining what's degraded. When OWUI is reachable, or gateway chat
/// is inactive, this returns [child] unchanged so the upstream UI is
/// byte-identical to the no-gateway path.
class GatewayConnectivityOverlay extends ConsumerWidget {
  const GatewayConnectivityOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gatewayChatActive = ref.watch(gatewayChatActiveProvider);
    if (!gatewayChatActive) return child;

    final connectivity = ref.watch(connectivityStatusProvider);
    if (connectivity != ConnectivityStatus.offline) return child;

    final mq = MediaQuery.of(context);
    final topInset = mq.viewPadding.top;

    // Push the routed body down so the banner sits above the AppBar instead of
    // covering it. The child sees `viewPadding.top = 0` and `padding.top = 0`
    // so its SafeArea / status-bar-aware widgets don't double-pad.
    return Column(
      children: [
        _OwuiOfflineBanner(topInset: topInset),
        Expanded(
          child: MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(top: 0),
              viewPadding: mq.viewPadding.copyWith(top: 0),
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

class _OwuiOfflineBanner extends ConsumerWidget {
  const _OwuiOfflineBanner({required this.topInset});

  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final iconData = Platform.isIOS
        ? CupertinoIcons.cloud_bolt
        : Icons.cloud_off_rounded;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDetails(context, ref),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            Spacing.md,
            topInset + Spacing.xs,
            Spacing.md,
            Spacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.warningBackground,
            border: Border(
              bottom: BorderSide(
                color: theme.warning.withValues(alpha: 0.35),
                width: BorderWidth.regular,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(iconData, size: IconSize.md, color: theme.warning),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'OWUI unreachable — sync paused. Gateway features still work.',
                  style: theme.bodySmall?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.chevron_right
                    : Icons.chevron_right_rounded,
                size: IconSize.sm,
                color: theme.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context, WidgetRef ref) async {
    await ThemedSheets.showSurface<void>(
      context: context,
      builder: (sheetContext) => const _OwuiOfflineDetails(),
    );
  }
}

class _OwuiOfflineDetails extends ConsumerStatefulWidget {
  const _OwuiOfflineDetails();

  @override
  ConsumerState<_OwuiOfflineDetails> createState() =>
      _OwuiOfflineDetailsState();
}

class _OwuiOfflineDetailsState extends ConsumerState<_OwuiOfflineDetails> {
  bool _retrying = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final activeServer = ref.read(activeServerProvider).asData?.value;
    final mirror = ref.read(owuiMirrorServiceProvider);
    final pending = mirror.pendingCount;
    final host = _hostOf(activeServer?.url);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Platform.isIOS
                    ? CupertinoIcons.cloud_bolt
                    : Icons.cloud_off_rounded,
                color: theme.warning,
                size: IconSize.lg,
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'OWUI sync paused',
                  style: theme.headingSmall?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (host != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              host,
              style: theme.bodySmall?.copyWith(
                color: theme.textSecondary,
                fontFamily: AppTypography.monospaceFontFamily,
              ),
            ),
          ],
          const SizedBox(height: Spacing.md),
          Text(
            "Your gateway is handling chat, voice, and speech locally. We'll catch OWUI up automatically when it's back.",
            style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.lg),
          _StatusSection(
            title: 'Still working',
            tone: theme.success,
            items: const [
              'Sending and receiving chat messages',
              'Voice calls, speech-to-text, text-to-speech',
              'Cached conversations and drafts',
            ],
          ),
          const SizedBox(height: Spacing.md),
          _StatusSection(
            title: pending == 0
                ? 'Queued for OWUI'
                : 'Queued for OWUI ($pending pending)',
            tone: theme.warning,
            items: const [
              'New messages waiting to mirror to other devices',
              'Conversation title and metadata edits',
            ],
          ),
          const SizedBox(height: Spacing.md),
          _StatusSection(
            title: "Won't work until OWUI is back",
            tone: theme.error,
            items: const [
              'File and attachment uploads',
              'Conversations created on other devices',
              'Account / profile changes',
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _retrying ? null : _retry,
                  icon: _retrying
                      ? SizedBox(
                          width: IconSize.sm,
                          height: IconSize.sm,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.textPrimary,
                          ),
                        )
                      : Icon(
                          Platform.isIOS
                              ? CupertinoIcons.refresh
                              : Icons.refresh_rounded,
                          size: IconSize.sm,
                        ),
                  label: Text(_retrying ? 'Checking…' : 'Check connection'),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Keep working'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      final service = ref.read(connectivityServiceProvider);
      final online = await service.checkNow();
      if (!mounted) return;
      if (online) {
        Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  String? _hostOf(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (uri.host.isNotEmpty) return uri.host;
    } catch (_) {}
    return url;
  }
}

class _StatusSection extends StatelessWidget {
  const _StatusSection({
    required this.title,
    required this.tone,
    required this.items,
  });

  final String title;
  final Color tone;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              title,
              style: theme.bodySmall?.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Padding(
          padding: const EdgeInsets.only(left: Spacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '• $item',
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
}
