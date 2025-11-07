import 'dart:async';
import 'dart:math' show sin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../models/voice_recording_state.dart';
import '../services/voice_input_service.dart';

/// Visual overlay showing current voice recording state
class VoiceRecordingOverlay extends ConsumerStatefulWidget {
  final VoiceRecordingState recordingState;
  final VoiceInputService voiceService;
  final VoidCallback? onTap;
  final VoidCallback? onLongPressStart;
  final VoidCallback? onLongPressEnd;

  const VoiceRecordingOverlay({
    super.key,
    required this.recordingState,
    required this.voiceService,
    this.onTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  ConsumerState<VoiceRecordingOverlay> createState() =>
      _VoiceRecordingOverlayState();
}

class _VoiceRecordingOverlayState
    extends ConsumerState<VoiceRecordingOverlay>
    with SingleTickerProviderStateMixin {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;
  late AnimationController _waveController;

  StreamSubscription<int>? _intensitySub;
  int _currentIntensity = 0;

  @override
  void initState() {
    super.initState();
    _duration = widget.recordingState.duration;
    _startDurationTimer();

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();

    // Listen to intensity stream for waveform
    _intensitySub = widget.voiceService.intensityStream.listen((intensity) {
      if (mounted) {
        setState(() {
          _currentIntensity = intensity;
        });
      }
    });
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _waveController.dispose();
    _intensitySub?.cancel();
    super.dispose();
  }

  void _startDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) {
        setState(() {
          _duration = widget.recordingState.duration;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final brightness = Theme.of(context).brightness;
    final mode = widget.recordingState.mode;
    // Check if actually using server STT at runtime
    final usingServerStt = widget.voiceService.usingServerStt;

    Color statusColor;
    String statusText;
    String helpText;
    IconData statusIcon;

    switch (mode) {
      case VoiceRecordingMode.vad:
        statusColor = Colors.green;
        statusText = '🎤 Recording';
        // Show advanced controls only when using server STT
        helpText = usingServerStt ? 'Tap to submit • Hold to pause' : 'Tap to submit';
        statusIcon = Icons.mic;
        break;
      case VoiceRecordingMode.vadPaused:
        statusColor = Colors.orange;
        statusText = '⏸️ Paused';
        helpText = 'Tap to submit • Release to resume';
        statusIcon = Icons.pause;
        break;
      case VoiceRecordingMode.processing:
        statusColor = Colors.red.shade700;
        statusText = '⏳ Processing';
        helpText = 'Transcribing audio...';
        statusIcon = Icons.sync;
        break;
      case VoiceRecordingMode.ptt:
        // PTT mode no longer used - fall through to VAD paused
        statusColor = Colors.orange;
        statusText = '⏸️ Paused';
        helpText = 'Tap to submit • Release to resume';
        statusIcon = Icons.pause;
        break;
    }

    // Simple card widget - gestures handled by OverlayEntry in parent
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardBackground.withValues(
          alpha: brightness == Brightness.dark ? 0.95 : 0.98,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.5),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: 0.2),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status row
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, color: statusColor, size: 20),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _formatDuration(_duration),
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: 14,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Waveform visualization (not shown during processing)
          if (mode != VoiceRecordingMode.processing)
            _buildWaveform(statusColor)
          else
            // Show spinner during processing
            SizedBox(
              height: 40,
              child: Center(
                child: CircularProgressIndicator(
                  color: statusColor,
                  strokeWidth: 3,
                ),
              ),
            ),

          const SizedBox(height: 12),

          // Help text
          Text(
            helpText,
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildWaveform(Color color) {
    return SizedBox(
      height: 40,
      child: AnimatedBuilder(
        animation: _waveController,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(15, (index) {
              final offset = (_waveController.value * 2 * 3.14159) +
                  (index * 0.4);
              final baseHeight = 0.3 + (0.7 * _currentIntensity / 10);
              final height = baseHeight + 0.2 * (1 + sin(offset));
              return Container(
                width: 4,
                height: 40 * height.clamp(0.2, 1.0),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    final tenths = (duration.inMilliseconds % 1000) ~/ 100;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${tenths}';
  }
}

