import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/markdown_to_text.dart';
import '../../../l10n/app_localizations.dart';
import '../services/voice_call_service.dart';

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key});

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage>
    with TickerProviderStateMixin {
  VoiceCallService? _service;
  
  // Subscriptions
  StreamSubscription<VoiceCallState>? _stateSubscription;
  StreamSubscription<String>? _transcriptSubscription;
  StreamSubscription<String>? _responseSubscription;
  StreamSubscription<int>? _intensitySubscription;
  StreamSubscription<bool>? _vadPausedSubscription;

  // State
  VoiceCallState _currentState = VoiceCallState.idle;
  String _currentTranscript = '';
  String _currentResponse = '';
  int _currentIntensity = 0;
  bool _isVadPaused = false;

  // Animation
  late AnimationController _pulseController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCall();
    });
  }

  Future<void> _initializeCall() async {
    try {
      _service = ref.read(voiceCallServiceProvider);

      // Set haptic feedback for response chunks
      _service!.setResponseChunkCallback(() {
        HapticFeedback.lightImpact();
      });

      // Subscribe to state changes
      _stateSubscription = _service!.stateStream.listen((state) {
        if (mounted) {
          setState(() => _currentState = state);
        }
      });

      _transcriptSubscription = _service!.transcriptStream.listen((text) {
        if (mounted) {
          setState(() => _currentTranscript = text);
        }
      });

      _responseSubscription = _service!.responseStream.listen((text) {
        if (mounted) {
          setState(() => _currentResponse = text);
        }
      });

      _intensitySubscription = _service!.intensityStream.listen((intensity) {
        if (mounted) {
          setState(() => _currentIntensity = intensity);
        }
      });

      _vadPausedSubscription = _service!.vadPausedStream.listen((isPaused) {
        if (mounted) {
          setState(() => _isVadPaused = isPaused);
        }
      });

      // Initialize and start call
      await _service!.initialize();
      final activeConversation = ref.read(activeConversationProvider);
      await _service!.startCall(activeConversation?.id);
    } catch (e) {
      if (mounted) {
        _showErrorDialog(e.toString());
      }
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) {
        final dialogL10n = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: Text(dialogL10n.error),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: Text(dialogL10n.ok),
            ),
          ],
        );
      },
    );
  }

  void _toggleVadPause() {
    if (_currentState != VoiceCallState.listening) return;

    HapticFeedback.heavyImpact();

    if (_isVadPaused) {
      _service?.resumeVad();
    } else {
      _service?.pauseVad();
    }
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _transcriptSubscription?.cancel();
    _responseSubscription?.cancel();
    _intensitySubscription?.cancel();
    _vadPausedSubscription?.cancel();
    _service?.stopCall();
    _pulseController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = ref.watch(selectedModelProvider);
    final primaryColor = Theme.of(context).colorScheme.primary;
    final backgroundColor = Theme.of(context).scaffoldBackgroundColor;
    final textColor = Theme.of(context).colorScheme.onSurface;
    final l10n = AppLocalizations.of(context)!;

    final vadPauseColor = Colors.amber.shade700;
    final effectiveColor = _isVadPaused ? vadPauseColor : primaryColor;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: Text(l10n.voiceCallTitle),
        leading: IconButton(
          icon: const Icon(CupertinoIcons.xmark),
          onPressed: () async {
            await _service?.stopCall();
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
        ),
      ),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleVadPause,
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Model name
                    Text(
                      selectedModel?.name ?? '',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: textColor.withValues(alpha: 0.7),
                          ),
                    ),
                    const SizedBox(height: 48),
                    
                    // Status indicator
                    _buildStatusIndicator(effectiveColor, textColor),
                    const SizedBox(height: 48),
                    
                    // State label
                    Text(
                      _getStateLabel(l10n),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _isVadPaused ? vadPauseColor : null,
                          ),
                    ),
                    
                    // VAD pause hint
                    if (_isVadPaused && _currentState == VoiceCallState.listening)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          l10n.voiceCallVadPaused,
                          style: TextStyle(
                            fontSize: 14,
                            color: vadPauseColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    
                    const SizedBox(height: 32),
                    
                    // Transcript or response
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: _buildTextDisplay(textColor),
                    ),
                    
                    // Error help
                    if (_currentState == VoiceCallState.error)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 32,
                          vertical: 16,
                        ),
                        child: Text(
                          l10n.voiceCallErrorHelp,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.error,
                            height: 1.5,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              
              // Control buttons (prevent tap-through)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: _buildControlButtons(primaryColor, l10n),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(Color activeColor, Color textColor) {
    if (_currentState == VoiceCallState.listening) {
      // Animated waveform
      return SizedBox(
        height: 120,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(5, (index) {
            return AnimatedBuilder(
              animation: _waveController,
              builder: (context, child) {
                final offset = (index * 0.2) % 1.0;
                final animation = (_waveController.value + offset) % 1.0;
                final height = 20.0 +
                    (math.sin(animation * math.pi * 2) * 30.0).abs() +
                    (_currentIntensity * 4.0);
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 8,
                  height: height,
                  decoration: BoxDecoration(
                    color: activeColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              },
            );
          }),
        ),
      );
    } else if (_currentState == VoiceCallState.speaking) {
      // Pulsing speaker
      return AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final scale = 1.0 + (_pulseController.value * 0.2);
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: activeColor.withValues(alpha: 0.2),
                border: Border.all(color: activeColor, width: 3),
              ),
              child: Center(
                child: Icon(
                  CupertinoIcons.speaker_2_fill,
                  size: 48,
                  color: activeColor,
                ),
              ),
            ),
          );
        },
      );
    } else if (_currentState == VoiceCallState.processing) {
      // Spinner
      return SizedBox(
        width: 120,
        height: 120,
        child: CircularProgressIndicator(
          strokeWidth: 3,
          valueColor: AlwaysStoppedAnimation<Color>(activeColor),
        ),
      );
    } else {
      // Default icon
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: textColor.withValues(alpha: 0.1),
        ),
        child: Icon(
          CupertinoIcons.mic_fill,
          size: 48,
          color: textColor.withValues(alpha: 0.5),
        ),
      );
    }
  }

  Widget _buildTextDisplay(Color textColor) {
    String displayText = '';
    
    if (_currentState == VoiceCallState.listening && _currentTranscript.isNotEmpty) {
      displayText = _currentTranscript;
    } else if ((_currentState == VoiceCallState.speaking ||
            _currentState == VoiceCallState.processing) &&
        _currentResponse.isNotEmpty) {
      displayText = MarkdownToText.convert(_currentResponse);
    }

    if (displayText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: SingleChildScrollView(
        child: Text(
          displayText,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: textColor.withValues(alpha: 0.8),
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildControlButtons(Color primaryColor, AppLocalizations l10n) {
    final errorColor = Theme.of(context).colorScheme.error;
    final warningColor = Colors.orange;
    final successColor = Theme.of(context).colorScheme.secondary;

    final buttons = <Widget>[];

    // Retry button (error state only)
    if (_currentState == VoiceCallState.error) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.arrow_clockwise,
          label: l10n.retry,
          color: primaryColor,
          onPressed: _initializeCall,
        ),
      );
    }

    // Manual send button (listening state only)
    if (_currentState == VoiceCallState.listening) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.paperplane_fill,
          label: l10n.voiceCallSend,
          color: primaryColor,
          onPressed: () => _service?.manualSend(),
        ),
      );
    }

    // Pause/Resume button
    if (_currentState == VoiceCallState.listening) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.pause_fill,
          label: l10n.voiceCallPause,
          color: warningColor,
          onPressed: () => _service?.pauseListening(),
        ),
      );
    } else if (_currentState == VoiceCallState.paused) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.play_fill,
          label: l10n.voiceCallResume,
          color: successColor,
          onPressed: () => _service?.resumeListening(),
        ),
      );
    }

    // Mute button (speaking or processing with content)
    if (_currentState == VoiceCallState.speaking ||
        (_currentState == VoiceCallState.processing && _currentResponse.isNotEmpty)) {
      buttons.add(
        _buildActionButton(
          icon: CupertinoIcons.speaker_slash_fill,
          label: l10n.voiceCallMute,
          color: warningColor,
          onPressed: () => _service?.muteSpeaking(),
        ),
      );
    }

    // End call button (always available)
    buttons.add(
      _buildActionButton(
        icon: CupertinoIcons.phone_down_fill,
        label: l10n.voiceCallEnd,
        color: errorColor,
        onPressed: () async {
          await _service?.stopCall();
          if (mounted) {
            Navigator.of(context).pop();
          }
        },
      ),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: buttons,
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }

  String _getStateLabel(AppLocalizations l10n) {
    if (_isVadPaused && _currentState == VoiceCallState.listening) {
      return l10n.voiceCallListeningHold;
    }

    return switch (_currentState) {
      VoiceCallState.idle => l10n.voiceCallReady,
      VoiceCallState.connecting => l10n.voiceCallConnecting,
      VoiceCallState.listening => l10n.voiceCallListening,
      VoiceCallState.paused => l10n.voiceCallPaused,
      VoiceCallState.processing => l10n.voiceCallProcessing,
      VoiceCallState.speaking => l10n.voiceCallSpeaking,
      VoiceCallState.error => l10n.error,
      VoiceCallState.disconnected => l10n.voiceCallDisconnected,
    };
  }
}