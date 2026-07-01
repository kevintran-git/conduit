import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../features/auth/providers/unified_auth_providers.dart';
import '../../../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../../config/gateway_providers.dart';
import '../application/call_session.dart';
import '../application/realtime_call_session.dart';
import 'gateway_call_overlay.dart';
import 'gateway_realtime_call_overlay.dart';

/// Drop-in replacement for upstream's [VoiceCallLauncher] that inserts the
/// call surface as an [OverlayEntry] over the chat screen instead of pushing
/// a full-page route. Chat scroll and streaming text stay visible while the
/// call is active.
///
/// Wired by overriding `voiceCallLauncherProvider` in the root ProviderScope
/// (see main.dart). Upstream code that calls `ref.read(...).launch(...)`
/// transparently lands here.
class GatewayCallLauncher extends VoiceCallLauncher {
  GatewayCallLauncher(this._ref) : super(_ref);

  final Ref _ref;

  /// Active overlay entry, or null if no call is in flight. We keep this on
  /// the launcher (not the controller) because the OverlayEntry is a
  /// widget-tree concern, not an inference concern.
  OverlayEntry? _entry;
  bool _realtimeActive = false;

  @override
  Future<void> launch({required bool startNewConversation}) async {
    final navState = _ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      throw StateError('Sign in to start a voice call.');
    }
    final cfg = _ref.read(gatewayConfigProvider);
    final realtime = cfg.realtimeEnabled;
    if (realtime) {
      if (!cfg.hasCredentials) {
        throw StateError('Voice gateway is not configured.');
      }
    } else if (!cfg.voiceEnabled || !cfg.hasCredentials) {
      throw StateError('Voice gateway is not configured.');
    }
    if (!realtime && _ref.read(selectedModelProvider) == null) {
      throw StateError('Choose a model before starting a voice call.');
    }
    if (_entry != null) {
      return;
    }

    if (NavigationService.currentRoute != Routes.chat) {
      await NavigationService.navigateToChat();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final context = NavigationService.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      throw StateError('Navigation context not available.');
    }
    FocusScope.of(context).unfocus();

    final overlay = NavigationService.navigatorKey.currentState?.overlay;
    if (overlay == null) {
      throw StateError('Overlay not available.');
    }
    final completer = Completer<void>();
    _realtimeActive = realtime;

    void close() {
      if (_entry == null) return;
      _entry!.remove();
      _entry = null;
      if (_realtimeActive) {
        _ref.invalidate(realtimeCallSessionProvider);
      } else {
        _ref.invalidate(callSessionProvider);
      }
      if (!completer.isCompleted) completer.complete();
    }

    _entry = OverlayEntry(
      builder: (_) => Align(
        alignment: Alignment.bottomCenter,
        child: realtime
            ? GatewayRealtimeCallOverlay(onClose: close)
            : GatewayCallOverlay(onClose: close),
      ),
    );
    overlay.insert(_entry!);
    return completer.future;
  }
}
