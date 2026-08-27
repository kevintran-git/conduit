/// Immutable configuration for the inference gateway.
///
/// Holds the gateway base URL, API key, and per-service feature toggles.
/// When all toggles are `false` (the default), no gateway code paths run and
/// upstream Open WebUI behavior is preserved byte-for-byte.
class GatewayConfig {
  const GatewayConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.sttEnabled,
    required this.ttsEnabled,
    required this.voiceEnabled,
    required this.ttsModel,
    required this.ttsVoice,
    required this.voiceManualMode,
    required this.realtimeEnabled,
    this.sttModel = '',
    this.callModel = defaultCallModel,
    this.callVoice = defaultCallVoice,
    this.callPauseToleranceMs = defaultCallPauseToleranceMs,
    this.callPrefixPaddingMs = defaultCallPrefixPaddingMs,
    this.callStartSensitivity = defaultCallSensitivity,
    this.callEndSensitivity = defaultCallSensitivity,
    this.callSystemPrompt,
    this.statsToolEnabled = false,
  });

  /// Default base URL — the user's own OpenAI-compatible gateway. The user
  /// can override this in settings; future support for self-hosted endpoints
  /// just changes this string.
  static const String defaultBaseUrl = 'https://api.kvt.codes';
  static const String defaultTtsModel = 'tts-1';
  static const String defaultTtsVoice = 'alloy';
  static const String defaultCallModel = 'gemini-3.1-flash-live-preview';
  static const String defaultCallVoice = 'Puck';
  static const int defaultCallPauseToleranceMs = 800;
  static const int defaultCallPrefixPaddingMs = 300;
  static const String defaultCallSensitivity = 'LOW';

  static const String envBaseUrl = String.fromEnvironment('GATEWAY_BASE_URL');
  static const String envApiKey = String.fromEnvironment('GATEWAY_API_KEY');
  static bool get hasEnvCredentials =>
      envBaseUrl.isNotEmpty && envApiKey.isNotEmpty;

  /// Off-by-default configuration. On first app launch this is what every
  /// shim point sees, which means inference still routes through OWUI until
  /// the user opts in.
  factory GatewayConfig.defaults() => const GatewayConfig(
    baseUrl: defaultBaseUrl,
    apiKey: '',
    sttEnabled: false,
    ttsEnabled: false,
    voiceEnabled: false,
    sttModel: '',
    ttsModel: defaultTtsModel,
    ttsVoice: defaultTtsVoice,
    voiceManualMode: false,
    realtimeEnabled: false,
    callModel: defaultCallModel,
    callVoice: defaultCallVoice,
    callPauseToleranceMs: defaultCallPauseToleranceMs,
    callPrefixPaddingMs: defaultCallPrefixPaddingMs,
    callStartSensitivity: defaultCallSensitivity,
    callEndSensitivity: defaultCallSensitivity,
    callSystemPrompt: null,
    statsToolEnabled: false,
  );

  final String baseUrl;
  final String apiKey;
  final bool sttEnabled;
  final bool ttsEnabled;
  final bool voiceEnabled;

  /// `backend` from `/v1/audio/transcription/capabilities`. Empty leaves the
  /// server on its `default_backend`.
  final String sttModel;

  final String ttsModel;
  final String ttsVoice;

  /// When true, the call screen disables VAD entirely — pure push-to-talk.
  /// Default false: VAD with manual override (press to suppress).
  final bool voiceManualMode;

  final bool realtimeEnabled;

  final String callModel;
  final String callVoice;

  final int callPauseToleranceMs;

  final int callPrefixPaddingMs;

  final String callStartSensitivity;
  final String callEndSensitivity;

  /// Optional system prompt injected at the start of every voice call turn
  /// when the Open WebUI server has not already provided one. Use this to
  /// instruct the model to keep replies short, avoid markdown, etc.
  /// Null / empty = no injection (model uses its own defaults).
  final String? callSystemPrompt;

  final bool statsToolEnabled;

  /// True when any service is enabled — used by shim points as a fast-path
  /// short-circuit. Returns false in the common (gateway-off) case so the
  /// hot path on existing OWUI users is one boolean check.
  bool get anyEnabled => sttEnabled || ttsEnabled || voiceEnabled;

  /// True when the config is well-formed enough to actually send traffic.
  /// Toggles ON without a URL+key are inert — the shim falls back to OWUI.
  bool get hasCredentials => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  GatewayConfig copyWith({
    String? baseUrl,
    String? apiKey,
    bool? sttEnabled,
    bool? ttsEnabled,
    bool? voiceEnabled,
    String? sttModel,
    String? ttsModel,
    String? ttsVoice,
    bool? voiceManualMode,
    bool? realtimeEnabled,
    String? callModel,
    String? callVoice,
    int? callPauseToleranceMs,
    int? callPrefixPaddingMs,
    String? callStartSensitivity,
    String? callEndSensitivity,
    Object? callSystemPrompt = _keep,
    bool? statsToolEnabled,
  }) {
    return GatewayConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      sttEnabled: sttEnabled ?? this.sttEnabled,
      ttsEnabled: ttsEnabled ?? this.ttsEnabled,
      voiceEnabled: voiceEnabled ?? this.voiceEnabled,
      sttModel: sttModel ?? this.sttModel,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      voiceManualMode: voiceManualMode ?? this.voiceManualMode,
      realtimeEnabled: realtimeEnabled ?? this.realtimeEnabled,
      callModel: callModel ?? this.callModel,
      callVoice: callVoice ?? this.callVoice,
      callPauseToleranceMs: callPauseToleranceMs ?? this.callPauseToleranceMs,
      callPrefixPaddingMs: callPrefixPaddingMs ?? this.callPrefixPaddingMs,
      callStartSensitivity: callStartSensitivity ?? this.callStartSensitivity,
      callEndSensitivity: callEndSensitivity ?? this.callEndSensitivity,
      callSystemPrompt: callSystemPrompt is _Sentinel
          ? this.callSystemPrompt
          : callSystemPrompt as String?,
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
        other.sttEnabled == sttEnabled &&
        other.ttsEnabled == ttsEnabled &&
        other.voiceEnabled == voiceEnabled &&
        other.sttModel == sttModel &&
        other.ttsModel == ttsModel &&
        other.ttsVoice == ttsVoice &&
        other.voiceManualMode == voiceManualMode &&
        other.realtimeEnabled == realtimeEnabled &&
        other.callModel == callModel &&
        other.callVoice == callVoice &&
        other.callPauseToleranceMs == callPauseToleranceMs &&
        other.callPrefixPaddingMs == callPrefixPaddingMs &&
        other.callStartSensitivity == callStartSensitivity &&
        other.callEndSensitivity == callEndSensitivity &&
        other.callSystemPrompt == callSystemPrompt &&
        other.statsToolEnabled == statsToolEnabled;
  }

  @override
  int get hashCode => Object.hashAll([
    baseUrl,
    apiKey,
    sttEnabled,
    ttsEnabled,
    voiceEnabled,
    sttModel,
    ttsModel,
    ttsVoice,
    voiceManualMode,
    realtimeEnabled,
    callModel,
    callVoice,
    callPauseToleranceMs,
    callPrefixPaddingMs,
    callStartSensitivity,
    callEndSensitivity,
    callSystemPrompt,
    statsToolEnabled,
  ]);
}

class _Sentinel {
  const _Sentinel();
}
