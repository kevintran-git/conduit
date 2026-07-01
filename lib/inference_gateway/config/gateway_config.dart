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
    required this.realtimeEnabled,
    this.callSystemPrompt,
    this.mcpEnabled = false,
    this.mcpServerUrl = '',
    this.mcpBearerToken = '',
    this.statsToolEnabled = false,
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
    realtimeEnabled: false,
    callSystemPrompt: null,
    mcpEnabled: false,
    mcpServerUrl: '',
    mcpBearerToken: '',
    statsToolEnabled: false,
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

  // Switches the call launcher from the STT/LLM/TTS pipeline to the full-duplex Gemini Live session. [fact]
  final bool realtimeEnabled;

  /// Optional system prompt injected at the start of every voice call turn
  /// when the Open WebUI server has not already provided one. Use this to
  /// instruct the model to keep replies short, avoid markdown, etc.
  /// Null / empty = no injection (model uses its own defaults).
  final String? callSystemPrompt;

  final bool mcpEnabled;
  final String mcpServerUrl;
  final String mcpBearerToken;

  // Backs the "get_chat_usage_stats" tool via OWUI's GET /api/v1/chats/stats/usage. [fact]
  final bool statsToolEnabled;

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
    bool? realtimeEnabled,
    Object? callSystemPrompt = _keep,
    bool? mcpEnabled,
    String? mcpServerUrl,
    String? mcpBearerToken,
    bool? statsToolEnabled,
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
      realtimeEnabled: realtimeEnabled ?? this.realtimeEnabled,
      callSystemPrompt: callSystemPrompt is _Sentinel
          ? this.callSystemPrompt
          : callSystemPrompt as String?,
      mcpEnabled: mcpEnabled ?? this.mcpEnabled,
      mcpServerUrl: mcpServerUrl ?? this.mcpServerUrl,
      mcpBearerToken: mcpBearerToken ?? this.mcpBearerToken,
      statsToolEnabled: statsToolEnabled ?? this.statsToolEnabled,
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
        other.realtimeEnabled == realtimeEnabled &&
        other.callSystemPrompt == callSystemPrompt &&
        other.mcpEnabled == mcpEnabled &&
        other.mcpServerUrl == mcpServerUrl &&
        other.mcpBearerToken == mcpBearerToken &&
        other.statsToolEnabled == statsToolEnabled;
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
    realtimeEnabled,
    callSystemPrompt,
    mcpEnabled,
    mcpServerUrl,
    mcpBearerToken,
    statsToolEnabled,
  );
}

class _Sentinel {
  const _Sentinel();
}
