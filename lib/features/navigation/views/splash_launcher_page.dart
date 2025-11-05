import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

class SplashLauncherPage extends ConsumerStatefulWidget {
  const SplashLauncherPage({super.key});

  @override
  ConsumerState<SplashLauncherPage> createState() =>
      _SplashLauncherPageState();
}

class _SplashLauncherPageState extends ConsumerState<SplashLauncherPage> {
  Timer? _timeoutTimer;
  bool _showTimeout = false;
  bool _isRecovering = false;
  int _tapCount = 0;
  Timer? _tapResetTimer;

  @override
  void initState() {
    super.initState();
    // Show timeout recovery options after 45 seconds
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      if (mounted) {
        setState(() {
          _showTimeout = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _tapResetTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _tapCount++;
    
    // Reset tap count after 1 second
    _tapResetTimer?.cancel();
    _tapResetTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _tapCount = 0;
        });
      }
    });

    // Show recovery screen on triple tap
    if (_tapCount >= 3) {
      _tapResetTimer?.cancel();
      _timeoutTimer?.cancel();
      setState(() {
        _showTimeout = true;
        _tapCount = 0;
      });
    }
  }

  Future<void> _handleLogout() async {
    setState(() {
      _isRecovering = true;
    });

    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.clearAuthData();
      await storage.setActiveServerId(null);
      
      ref.invalidate(authStateManagerProvider);
      ref.invalidate(activeServerProvider);

      if (mounted) {
        context.go(Routes.serverConnection);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecovering = false;
        });
      }
    }
  }

  Future<void> _handleRetry() async {
    setState(() {
      _isRecovering = true;
      _showTimeout = false;
    });

    try {
      ref.invalidate(authStateManagerProvider);
      
      // Reset timeout timer
      _timeoutTimer?.cancel();
      _timeoutTimer = Timer(const Duration(seconds: 45), () {
        if (mounted) {
          setState(() {
            _showTimeout = true;
            _isRecovering = false;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRecovering = false;
          _showTimeout = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    
    // Listen to auth state to detect errors
    ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (prev, next) {
      final state = next.asData?.value;
      if (state?.status == AuthStatus.error && mounted) {
        // Show timeout UI immediately on error
        setState(() {
          _showTimeout = true;
        });
      }
    });

    return Scaffold(
      backgroundColor: context.conduitTheme.surfaceBackground,
      body: SafeArea(
        child: Center(
          child: _showTimeout
              ? _buildTimeoutRecovery(context, l10n)
              : _buildLoading(context, l10n),
        ),
      ),
    );
  }

  Widget _buildLoading(BuildContext context, AppLocalizations? l10n) {
    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(
            context.conduitTheme.loadingIndicator,
          ),
        ),
      ),
    );
  }

  Widget _buildTimeoutRecovery(BuildContext context, AppLocalizations? l10n) {
    final authState = ref.watch(authStateManagerProvider).asData?.value;
    final errorMessage = authState?.error;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: context.conduitTheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: context.conduitTheme.error.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: Icon(
              Platform.isIOS
                  ? CupertinoIcons.exclamationmark_triangle
                  : Icons.error_outline,
              color: context.conduitTheme.error,
              size: 28,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l10n?.connectionTimeout ?? 'Connection Timeout',
            textAlign: TextAlign.center,
            style: context.conduitTheme.headingMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: context.conduitTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            errorMessage ??
                (l10n?.connectionTimeoutMessage ??
                    'The app is taking longer than expected to connect. This might be due to a slow connection or server timeout.'),
            textAlign: TextAlign.center,
            style: context.conduitTheme.bodyMedium?.copyWith(
              color: context.conduitTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConduitButton(
                  text: l10n?.retry ?? 'Retry',
                  onPressed: _isRecovering ? null : _handleRetry,
                  isLoading: _isRecovering,
                  icon: Platform.isIOS
                      ? CupertinoIcons.refresh
                      : Icons.refresh_rounded,
                  isFullWidth: true,
                ),
                const SizedBox(height: 12),
                ConduitButton(
                  text: l10n?.signOut ?? 'Sign Out',
                  onPressed: _isRecovering ? null : _handleLogout,
                  isSecondary: true,
                  icon: Platform.isIOS
                      ? CupertinoIcons.arrow_turn_up_left
                      : Icons.logout,
                  isFullWidth: true,
                  isCompact: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
