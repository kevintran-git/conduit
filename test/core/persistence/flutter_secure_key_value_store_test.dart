import 'package:checks/checks.dart';
import 'package:conduit/platform/flutter_secure_key_value_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes legacy Android storageNamespace and prefix options', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    Map<Object?, Object?>? capturedOptions;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map<Object?, Object?>?;
          capturedOptions = args?['options'] as Map<Object?, Object?>?;
          return 'stored-value';
        });

    final store = FlutterSecureKeyValueStore();
    final value = await store.read(key: 'auth_token');

    check(value).equals('stored-value');
    check(capturedOptions).isNotNull();
    check(capturedOptions!['storageNamespace']).equals('conduit_secure_prefs');
    check(capturedOptions!['preferencesKeyPrefix']).equals('conduit_');
    check(capturedOptions!['resetOnError']).equals('false');
  });
}
