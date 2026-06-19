import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../features/auth/providers/unified_auth_providers.dart';
import '../../../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../../config/gateway_providers.dart';
import '../application/call_session.dart';
import 'gateway_call_overlay.dart';

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

  @override
  Future<void> launch({required bool startNewConversation}) async {
    final navState = _ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      throw StateError('Sign in to start a voice call.');
    }
    // Preflight: refuse to open the overlay if the gateway voice path isn't
    // usable. Without this the call surface opens then immediately flips
    // to an error stage, which reads as a crash to the user.
    final cfg = _ref.read(gatewayConfigProvider);
    if (!cfg.voiceEnabled || !cfg.hasCredentials) {
      throw StateError('Voice gateway is not configured.');
    }
    if (_ref.read(selectedModelProvider) == null) {
      throw StateError('Choose a model before starting a voice call.');
    }
    if (_entry != null) {
      // Already in a call — bringing it forward is a no-op for the overlay
      // model since it's already on top of the chat.
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

    // navigatorKey.currentContext sits at the Navigator widget itself, which
    // is above its own Overlay — so Overlay.of from there finds nothing.
    // Use the Navigator's state directly: it exposes the internal Overlay.
    final overlay = NavigationService.navigatorKey.currentState?.overlay;
    if (overlay == null) {
      throw StateError('Overlay not available.');
    }
    final completer = Completer<void>();

    void close() {
      if (_entry == null) return;
      _entry!.remove();
      _entry = null;
      // Tearing down the controller triggers all its onDispose hooks
      // (closes WS, releases mic, stops TTS).
      _ref.invalidate(callSessionProvider);
      if (!completer.isCompleted) completer.complete();
    }

    _entry = OverlayEntry(
      builder: (_) => Align(
        alignment: Alignment.bottomCenter,
        child: GatewayCallOverlay(onClose: close),
      ),
    );
    overlay.insert(_entry!);
    return completer.future;
  }
}
