import 'package:flutter/material.dart';

/// Manages full-screen overlays for PTT and VAD pause modes
class VoiceRecordingOverlayManager {
  OverlayEntry? _pttOverlay;
  OverlayEntry? _vadPauseOverlay;
  OverlayEntry? _initialPressOverlay;

  /// Show PTT overlay that captures release anywhere on screen
  void showPttOverlay(
    BuildContext context,
    VoidCallback onRelease,
    bool Function() isPttMode,
    bool Function() isPressed,
  ) {
    removePttOverlay();

    _pttOverlay = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            // Safety escape: tap after releasing initial hold
            if (!isPressed() && isPttMode()) {
              onRelease();
            }
          },
          onPointerUp: (event) {
            if (isPttMode()) {
              onRelease();
            }
          },
          onPointerCancel: (event) {
            if (isPttMode()) {
              onRelease();
            }
          },
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    Overlay.of(context).insert(_pttOverlay!);
  }

  /// Show VAD pause overlay that captures release anywhere on screen
  void showVadPauseOverlay(
    BuildContext context,
    VoidCallback onResume,
    bool Function() isVadPaused,
    bool Function() isPressed,
  ) {
    removeVadPauseOverlay();

    _vadPauseOverlay = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            // Safety escape: tap after releasing initial hold
            if (!isPressed() && isVadPaused()) {
              onResume();
            }
          },
          onPointerUp: (event) {
            if (isVadPaused()) {
              onResume();
            }
          },
          onPointerCancel: (event) {
            if (isVadPaused()) {
              onResume();
            }
          },
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    Overlay.of(context).insert(_vadPauseOverlay!);
  }

  void removePttOverlay() {
    _pttOverlay?.remove();
    _pttOverlay = null;
  }

  void removeVadPauseOverlay() {
    _vadPauseOverlay?.remove();
    _vadPauseOverlay = null;
  }

  /// Show initial press overlay immediately when button is pressed
  /// This captures pointer events anywhere on screen from the very start
  /// Reuses the same pattern as PTT overlay
  void showInitialPressOverlay(
    BuildContext context,
    VoidCallback onPointerUp,
    VoidCallback onPointerCancel,
  ) {
    removeInitialPressOverlay();

    _initialPressOverlay = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerUp: (event) => onPointerUp(),
          onPointerCancel: (event) => onPointerCancel(),
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    Overlay.of(context).insert(_initialPressOverlay!);
  }

  void removeInitialPressOverlay() {
    _initialPressOverlay?.remove();
    _initialPressOverlay = null;
  }

  void removeAllOverlays() {
    removePttOverlay();
    removeVadPauseOverlay();
    removeInitialPressOverlay();
  }

  void dispose() {
    removeAllOverlays();
  }
}

