import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/services/navigation_service.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../../../features/chat/voice_call/presentation/voice_call_launcher.dart';
import '../../config/gateway_providers.dart';
import '../application/call_session.dart';
import 'gateway_call_overlay.dart';

///
class GatewayCallLauncher extends VoiceCallLauncher {
  GatewayCallLauncher(this._ref) : super(_ref);

  final Ref _ref;

  OverlayEntry? _entry;

  @override
  Future<void> launch({required bool startNewConversation}) async {
    final navState = _ref.read(authNavigationStateProvider);
    if (navState != AuthNavigationState.authenticated) {
      throw StateError('Sign in to start a voice call.');
    }
    final cfg = _ref.read(gatewayConfigProvider);
    final gatewayUsable = cfg.hasCredentials && cfg.voiceEnabled;
    if (!gatewayUsable) {
      return super.launch(startNewConversation: startNewConversation);
    }
    if (_ref.read(selectedModelProvider) == null) {
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

    void close() {
      if (_entry == null) return;
      _entry!.remove();
      _entry = null;
      _ref.invalidate(callSessionProvider);
      if (!completer.isCompleted) completer.complete();
    }

    _entry = OverlayEntry(
      builder: (_) => Align(
        alignment: Alignment.bottomCenter,
        child: Consumer(
          builder: (context, ref, _) {
            return GatewayCallOverlay(
              state: ref.watch(callSessionProvider),
              engine: ref.read(callSessionProvider.notifier),
              onClose: close,
            );
          },
        ),
      ),
    );
    overlay.insert(_entry!);
    return completer.future;
  }
}
