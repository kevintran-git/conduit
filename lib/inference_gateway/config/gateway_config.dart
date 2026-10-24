class GatewayConfig {
  const GatewayConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.ttsModel,
    required this.ttsVoice,
    required this.voiceManualMode,
  });

  static const String defaultBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
  );

  static const String unsetModel = '';

  static const String envApiKey = String.fromEnvironment('GATEWAY_API_KEY');
  static bool get hasEnvCredentials =>
      defaultBaseUrl.isNotEmpty && envApiKey.isNotEmpty;

  factory GatewayConfig.defaults() => const GatewayConfig(
    baseUrl: defaultBaseUrl,
    apiKey: '',
    ttsModel: unsetModel,
    ttsVoice: unsetModel,
    voiceManualMode: false,
  );

  final String baseUrl;
  final String apiKey;

  final String ttsModel;
  final String ttsVoice;

  final bool voiceManualMode;

  bool get hasCredentials => baseUrl.isNotEmpty && apiKey.isNotEmpty;

  GatewayConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? ttsModel,
    String? ttsVoice,
    bool? voiceManualMode,
  }) {
    return GatewayConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      voiceManualMode: voiceManualMode ?? this.voiceManualMode,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GatewayConfig &&
        other.baseUrl == baseUrl &&
        other.apiKey == apiKey &&
        other.ttsModel == ttsModel &&
        other.ttsVoice == ttsVoice &&
        other.voiceManualMode == voiceManualMode;
  }

  @override
  int get hashCode =>
      Object.hashAll([baseUrl, apiKey, ttsModel, ttsVoice, voiceManualMode]);
}
