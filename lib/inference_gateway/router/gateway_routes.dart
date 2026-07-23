import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../settings/gateway_settings_page.dart';

/// GoRouter routes owned by the inference gateway.
///
/// Spread into the app's route list with `...gatewayRoutes()` so that
/// `app_router.dart` keeps a single-line hook instead of an inline `GoRoute`
/// block, reducing rebase conflicts on that upstream-owned file.
List<RouteBase> gatewayRoutes() => [
  GoRoute(
    path: '/profile/gateway',
    name: 'gateway-settings',
    pageBuilder: (context, state) =>
        _platformPage(state: state, child: const GatewaySettingsPage()),
  ),
];

/// Mirrors `app_router.dart`'s private `_buildPlatformPage` so gateway routes
/// get the same platform-correct page transition without exporting it.
Page<void> _platformPage({
  required GoRouterState state,
  required Widget child,
}) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return CupertinoPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
    default:
      return MaterialPage<void>(
        key: state.pageKey,
        name: state.name,
        child: child,
      );
  }
}
