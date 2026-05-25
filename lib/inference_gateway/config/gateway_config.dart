/// Immutable configuration for the inference gateway.
///
/// Holds the gateway base URL, API key, and per-service feature toggles.
/// When all toggles are `false` (the default), no gateway code paths run and
/// upstream Open WebUI behavior is preserved byte-for-byte.
class GatewayConfig {
  const GatewayConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.chatEnabled,
    required this.sttEnabled,
    required this.ttsEnabled,
    required this.voiceEnabled,
    required this.ttsModel,
    required this.ttsVoice,
    required this.voiceManualMode,
    this.callSystemPrompt,
  });

  /// Default base URL — the user's own OpenAI-compatible gateway. The user
  /// can override this in settings; future support for self-hosted endpoints
  /// just changes this string.
  static const String defaultBaseUrl = 'https://api.kvt.codes';
  static const String defaultTtsModel = 'tts-1';
  static const String defaultTtsVoice = 'alloy';

  /// Off-by-default configuration. On first app launch this is what every
  /// shim point sees, which means inference still routes through OWUI until
  /// the user opts in.
  factory GatewayConfig.defaults() => const GatewayConfig(
    baseUrl: defaultBaseUrl,
    apiKey: '',
    chatEnabled: false,
    sttEnabled: false,
    ttsEnabled: false,
    voiceEnabled: false,
    ttsModel: defaultTtsModel,
    ttsVoice: defaultTtsVoice,
    voiceManualMode: false,
    callSystemPrompt: null,
  );

  final String baseUrl;
  final String apiKey;
  final bool chatEnabled;
  final bool sttEnabled;
  final bool ttsEnabled;
  final bool voiceEnabled;
  final String ttsModel;
  final String ttsVoice;

  /// When true, the call screen disables VAD entirely — pure push-to-talk.
  /// Default false: VAD with manual override (press to suppress).
  final bool voiceManualMode;

  /// Optional system prompt injected at the start of every voice call turn
  /// when the Open WebUI server has not already provided one. Use this to
  /// instruct the model to keep replies short, avoid markdown, etc.
  /// Null / empty = no injection (model uses its own defaults).
  final String? callSystemPrompt;

  /// True when any service is enabled — used by shim points as a fast-path
  /// short-circuit. Returns false in the common (gateway-off) case so the
  /// hot path on existing OWUI users is one boolean check.
  bool get anyEnabled =>
      chatEnabled || sttEnabled || ttsEnabled || voiceEnabled;

  /// True when the config is well-formed enough to actually send traffic.
  /// Toggles ON without a URL+key are inert — the shim falls back to OWUI.
  bool get hasCredentials => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  GatewayConfig copyWith({
    String? baseUrl,
    String? apiKey,
    bool? chatEnabled,
    bool? sttEnabled,
    bool? ttsEnabled,
    bool? voiceEnabled,
    String? ttsModel,
    String? ttsVoice,
    bool? voiceManualMode,
    Object? callSystemPrompt = _keep,
  }) {
    return GatewayConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      chatEnabled: chatEnabled ?? this.chatEnabled,
      sttEnabled: sttEnabled ?? this.sttEnabled,
      ttsEnabled: ttsEnabled ?? this.ttsEnabled,
      voiceEnabled: voiceEnabled ?? this.voiceEnabled,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      voiceManualMode: voiceManualMode ?? this.voiceManualMode,
      callSystemPrompt: callSystemPrompt is _Sentinel
          ? this.callSystemPrompt
          : callSystemPrompt as String?,
    );
  }

  static const Object _keep = _Sentinel();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GatewayConfig &&
        other.baseUrl == baseUrl &&
        other.apiKey == apiKey &&
        other.chatEnabled == chatEnabled &&
        other.sttEnabled == sttEnabled &&
        other.ttsEnabled == ttsEnabled &&
        other.voiceEnabled == voiceEnabled &&
        other.ttsModel == ttsModel &&
        other.ttsVoice == ttsVoice &&
        other.voiceManualMode == voiceManualMode &&
        other.callSystemPrompt == callSystemPrompt;
  }

  @override
  int get hashCode => Object.hash(
    baseUrl,
    apiKey,
    chatEnabled,
    sttEnabled,
    ttsEnabled,
    voiceEnabled,
    ttsModel,
    ttsVoice,
    voiceManualMode,
    callSystemPrompt,
  );
}

class _Sentinel {
  const _Sentinel();
}
