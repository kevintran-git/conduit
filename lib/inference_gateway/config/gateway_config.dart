///
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
    this.callModel = unsetModel,
    this.callVoice = unsetModel,
    this.callThinkingLevel = unsetThinkingLevel,
    this.callPauseToleranceMs = defaultCallPauseToleranceMs,
    this.callPrefixPaddingMs = defaultCallPrefixPaddingMs,
    this.callStartSensitivity = defaultCallSensitivity,
    this.callEndSensitivity = defaultCallSensitivity,
    this.callSystemPrompt,
    this.statsToolEnabled = false,
  });

  static const String defaultBaseUrl = 'https://api.kvt.codes';

  static const String unsetModel = '';

  static const String unsetThinkingLevel = '';
  static const int defaultCallPauseToleranceMs = 800;
  static const int defaultCallPrefixPaddingMs = 300;
  static const String defaultCallSensitivity = 'LOW';

  static const String envBaseUrl = String.fromEnvironment('GATEWAY_BASE_URL');
  static const String envApiKey = String.fromEnvironment('GATEWAY_API_KEY');
  static bool get hasEnvCredentials =>
      envBaseUrl.isNotEmpty && envApiKey.isNotEmpty;

  factory GatewayConfig.defaults() => const GatewayConfig(
    baseUrl: defaultBaseUrl,
    apiKey: '',
    sttEnabled: false,
    ttsEnabled: false,
    voiceEnabled: false,
    sttModel: '',
    ttsModel: unsetModel,
    ttsVoice: unsetModel,
    voiceManualMode: false,
    realtimeEnabled: false,
    callModel: unsetModel,
    callVoice: unsetModel,
    callThinkingLevel: unsetThinkingLevel,
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

  final String sttModel;

  final String ttsModel;
  final String ttsVoice;

  final bool voiceManualMode;

  final bool realtimeEnabled;

  final String callModel;
  final String callVoice;
  final String callThinkingLevel;

  final int callPauseToleranceMs;

  final int callPrefixPaddingMs;

  final String callStartSensitivity;
  final String callEndSensitivity;

  final String? callSystemPrompt;

  final bool statsToolEnabled;

  bool get anyEnabled => sttEnabled || ttsEnabled || voiceEnabled;

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
    String? callThinkingLevel,
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
      callThinkingLevel: callThinkingLevel ?? this.callThinkingLevel,
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
        other.callThinkingLevel == callThinkingLevel &&
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
    callThinkingLevel,
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
