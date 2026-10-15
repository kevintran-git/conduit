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
    this.sttModel = '',
  });

  static const String defaultBaseUrl = 'https://api.kvtr.tech';

  static const String unsetModel = '';

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
    );
  }

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
        other.voiceManualMode == voiceManualMode;
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
  ]);
}
