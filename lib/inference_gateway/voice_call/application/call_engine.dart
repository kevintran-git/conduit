abstract class CallEngine {
  Future<void> tapMicButton();
  Future<void> toggleMute();
  Future<void> setManualEosOnly(bool value);
  Future<void> end();
}
