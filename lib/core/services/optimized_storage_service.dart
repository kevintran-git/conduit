import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';

import '../models/conversation.dart';
import '../models/folder.dart';
import '../models/server_config.dart';
import '../persistence/hive_boxes.dart';
import '../persistence/persistence_keys.dart';
import '../utils/debug_logger.dart';
import 'secure_credential_storage.dart';
import 'worker_manager.dart';

/// Optimized storage service backed by Hive for non-sensitive data and
/// FlutterSecureStorage for credentials.
class OptimizedStorageService {
  OptimizedStorageService({
    required FlutterSecureStorage secureStorage,
    required HiveBoxes boxes,
    required WorkerManager workerManager,
  }) : _preferencesBox = boxes.preferences,
       _cachesBox = boxes.caches,
       _attachmentQueueBox = boxes.attachmentQueue,
       _metadataBox = boxes.metadata,
       _secureCredentialStorage = SecureCredentialStorage(
         instance: secureStorage,
       ),
       _workerManager = workerManager;

  final Box<dynamic> _preferencesBox;
  final Box<dynamic> _cachesBox;
  final Box<dynamic> _attachmentQueueBox;
  final Box<dynamic> _metadataBox;
  final SecureCredentialStorage _secureCredentialStorage;
  final WorkerManager _workerManager;

  static const String _authTokenKey = 'auth_token_v3';
  static const String _activeServerIdKey = PreferenceKeys.activeServerId;
  static const String _themeModeKey = PreferenceKeys.themeMode;
  static const String _themePaletteKey = PreferenceKeys.themePalette;
  static const String _localeCodeKey = PreferenceKeys.localeCode;
  static const String _localConversationsKey = HiveStoreKeys.localConversations;
  static const String _localFoldersKey = HiveStoreKeys.localFolders;
  static const String _onboardingSeenKey = PreferenceKeys.onboardingSeen;
  static const String _reviewerModeKey = PreferenceKeys.reviewerMode;

  final Map<String, dynamic> _cache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheTimeout = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // Auth token APIs (secure storage + in-memory cache)
  // ---------------------------------------------------------------------------
  Future<void> saveAuthToken(String token) async {
    try {
      await _secureCredentialStorage.saveAuthToken(token);
      _cache[_authTokenKey] = token;
      _cacheTimestamps[_authTokenKey] = DateTime.now();
      DebugLogger.log(
        'Auth token saved and cached',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save auth token: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<String?> getAuthToken() async {
    if (_isCacheValid(_authTokenKey)) {
      final cached = _cache[_authTokenKey] as String?;
      if (cached != null) {
        DebugLogger.log('Using cached auth token', scope: 'storage/optimized');
        return cached;
      }
    }

    try {
      final token = await _secureCredentialStorage.getAuthToken();
      if (token != null) {
        _cache[_authTokenKey] = token;
        _cacheTimestamps[_authTokenKey] = DateTime.now();
      }
      return token;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve auth token: $error',
        scope: 'storage/optimized',
      );
      return null;
    }
  }

  Future<void> deleteAuthToken() async {
    try {
      await _secureCredentialStorage.deleteAuthToken();
      _cache.remove(_authTokenKey);
      _cacheTimestamps.remove(_authTokenKey);
      DebugLogger.log(
        'Auth token deleted and cache cleared',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.error(
        'Failed to delete auth token',
        scope: 'storage/optimized',
        error: error,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Credential APIs (secure storage only)
  // ---------------------------------------------------------------------------
  Future<void> saveCredentials({
    required String serverId,
    required String username,
    required String password,
  }) async {
    try {
      await _secureCredentialStorage.saveCredentials(
        serverId: serverId,
        username: username,
        password: password,
      );

      _cache['has_credentials'] = true;
      _cacheTimestamps['has_credentials'] = DateTime.now();

      DebugLogger.log(
        'Credentials saved via optimized storage',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save credentials: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<Map<String, String>?> getSavedCredentials() async {
    try {
      final credentials = await _secureCredentialStorage.getSavedCredentials();
      _cache['has_credentials'] = credentials != null;
      _cacheTimestamps['has_credentials'] = DateTime.now();
      return credentials;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve credentials: $error',
        scope: 'storage/optimized',
      );
      return null;
    }
  }

  Future<void> deleteSavedCredentials() async {
    try {
      await _secureCredentialStorage.deleteSavedCredentials();
      _cache.remove('has_credentials');
      _cacheTimestamps.remove('has_credentials');
      DebugLogger.log(
        'Credentials deleted via optimized storage',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.error(
        'Failed to delete credentials',
        scope: 'storage/optimized',
        error: error,
      );
      rethrow;
    }
  }

  Future<bool> hasCredentials() async {
    if (_isCacheValid('has_credentials')) {
      return _cache['has_credentials'] == true;
    }
    final credentials = await getSavedCredentials();
    return credentials != null;
  }

  // ---------------------------------------------------------------------------
  // Preference helpers (Hive-backed)
  // ---------------------------------------------------------------------------
  Future<void> saveServerConfigs(List<ServerConfig> configs) async {
    try {
      final jsonString = jsonEncode(configs.map((c) => c.toJson()).toList());
      await _secureCredentialStorage.saveServerConfigs(jsonString);
      _cache['server_config_count'] = configs.length;
      _cacheTimestamps['server_config_count'] = DateTime.now();
      DebugLogger.log(
        'Server configs saved (${configs.length} entries)',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Failed to save server configs: $error',
        scope: 'storage/optimized',
      );
      rethrow;
    }
  }

  Future<List<ServerConfig>> getServerConfigs() async {
    try {
      final jsonString = await _secureCredentialStorage.getServerConfigs();
      if (jsonString == null || jsonString.isEmpty) {
        _cache['server_config_count'] = 0;
        _cacheTimestamps['server_config_count'] = DateTime.now();
        return const [];
      }

      final decoded = jsonDecode(jsonString) as List<dynamic>;
      final configs = decoded
          .map((item) => ServerConfig.fromJson(item))
          .toList();
      _cache['server_config_count'] = configs.length;
      _cacheTimestamps['server_config_count'] = DateTime.now();
      return configs;
    } catch (error) {
      DebugLogger.log(
        'Failed to retrieve server configs: $error',
        scope: 'storage/optimized',
      );
      return const [];
    }
  }

  Future<void> setActiveServerId(String? serverId) async {
    if (serverId != null) {
      await _preferencesBox.put(_activeServerIdKey, serverId);
    } else {
      await _preferencesBox.delete(_activeServerIdKey);
    }
    _cache[_activeServerIdKey] = serverId;
    _cacheTimestamps[_activeServerIdKey] = DateTime.now();
  }

  Future<String?> getActiveServerId() async {
    if (_isCacheValid(_activeServerIdKey)) {
      return _cache[_activeServerIdKey] as String?;
    }
    final serverId = _preferencesBox.get(_activeServerIdKey) as String?;
    _cache[_activeServerIdKey] = serverId;
    _cacheTimestamps[_activeServerIdKey] = DateTime.now();
    return serverId;
  }

  String? getThemeMode() {
    return _preferencesBox.get(_themeModeKey) as String?;
  }

  Future<void> setThemeMode(String mode) async {
    await _preferencesBox.put(_themeModeKey, mode);
  }

  String? getThemePaletteId() {
    return _preferencesBox.get(_themePaletteKey) as String?;
  }

  Future<void> setThemePaletteId(String paletteId) async {
    await _preferencesBox.put(_themePaletteKey, paletteId);
  }

  String? getLocaleCode() {
    return _preferencesBox.get(_localeCodeKey) as String?;
  }

  Future<void> setLocaleCode(String? code) async {
    if (code == null || code.isEmpty) {
      await _preferencesBox.delete(_localeCodeKey);
    } else {
      await _preferencesBox.put(_localeCodeKey, code);
    }
  }

  Future<bool> getOnboardingSeen() async {
    return (_preferencesBox.get(_onboardingSeenKey) as bool?) ?? false;
  }

  Future<void> setOnboardingSeen(bool seen) async {
    await _preferencesBox.put(_onboardingSeenKey, seen);
  }

  Future<bool> getReviewerMode() async {
    return (_preferencesBox.get(_reviewerModeKey) as bool?) ?? false;
  }

  Future<void> setReviewerMode(bool enabled) async {
    await _preferencesBox.put(_reviewerModeKey, enabled);
  }

  Future<List<Conversation>> getLocalConversations() async {
    try {
      final stored = _cachesBox.get(_localConversationsKey);
      if (stored == null) {
        return const [];
      }
      final parsed = await _workerManager
          .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
            _decodeStoredJsonListWorker,
            {'stored': stored},
            debugLabel: 'decode_local_conversations',
          );
      return parsed.map(Conversation.fromJson).toList(growable: false);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local conversations',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalConversations(List<Conversation> conversations) async {
    try {
      final jsonReady = conversations
          .map((conversation) => conversation.toJson())
          .toList();
      final serialized = await _workerManager
          .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
            'items': jsonReady,
          }, debugLabel: 'encode_local_conversations');
      await _cachesBox.put(_localConversationsKey, serialized);
      DebugLogger.log(
        'Saved ${conversations.length} local conversations',
        scope: 'storage/optimized',
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local conversations',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<List<Folder>> getLocalFolders() async {
    try {
      final stored = _cachesBox.get(_localFoldersKey);
      if (stored == null) {
        return const [];
      }
      final parsed = await _workerManager
          .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
            _decodeStoredJsonListWorker,
            {'stored': stored},
            debugLabel: 'decode_local_folders',
          );
      return parsed.map(Folder.fromJson).toList(growable: false);
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to retrieve local folders',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
      return const [];
    }
  }

  Future<void> saveLocalFolders(List<Folder> folders) async {
    try {
      final jsonReady = folders.map((folder) => folder.toJson()).toList();
      final serialized = await _workerManager
          .schedule<Map<String, dynamic>, String>(_encodeJsonListWorker, {
            'items': jsonReady,
          }, debugLabel: 'encode_local_folders');
      await _cachesBox.put(_localFoldersKey, serialized);
      DebugLogger.log(
        'Saved ${folders.length} local folders',
        scope: 'storage/optimized',
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to save local folders',
        scope: 'storage/optimized',
        error: error,
        stackTrace: stack,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Batch operations
  // ---------------------------------------------------------------------------
  Future<void> clearAuthData() async {
    await Future.wait([
      deleteAuthToken(),
      deleteSavedCredentials(),
      _preferencesBox.delete(_activeServerIdKey),
    ]);

    _cache.removeWhere(
      (key, _) =>
          key.contains('auth') ||
          key.contains('credentials') ||
          key.contains('server'),
    );
    _cacheTimestamps.removeWhere(
      (key, _) =>
          key.contains('auth') ||
          key.contains('credentials') ||
          key.contains('server'),
    );

    DebugLogger.log(
      'Auth data cleared in batch operation',
      scope: 'storage/optimized',
    );
  }

  Future<void> clearAll() async {
    try {
      await Future.wait([
        _secureCredentialStorage.clearAll(),
        _preferencesBox.clear(),
        _cachesBox.clear(),
        _attachmentQueueBox.clear(),
      ]);

      _cache.clear();
      _cacheTimestamps.clear();

      // Preserve migration metadata
      final migrationVersion =
          _metadataBox.get(HiveStoreKeys.migrationVersion) as int?;
      await _metadataBox.clear();
      if (migrationVersion != null) {
        await _metadataBox.put(
          HiveStoreKeys.migrationVersion,
          migrationVersion,
        );
      }

      DebugLogger.log('All storage cleared', scope: 'storage/optimized');
    } catch (error) {
      DebugLogger.log(
        'Failed to clear all storage: $error',
        scope: 'storage/optimized',
      );
    }
  }

  Future<bool> isSecureStorageAvailable() async {
    return _secureCredentialStorage.isSecureStorageAvailable();
  }

  // ---------------------------------------------------------------------------
  // Cache helpers
  // ---------------------------------------------------------------------------
  bool _isCacheValid(String key) {
    final timestamp = _cacheTimestamps[key];
    if (timestamp == null) {
      return false;
    }
    return DateTime.now().difference(timestamp) < _cacheTimeout;
  }

  void clearCache() {
    _cache.clear();
    _cacheTimestamps.clear();
    DebugLogger.log('Storage cache cleared', scope: 'storage/optimized');
  }

  // ---------------------------------------------------------------------------
  // Legacy migration hooks (no-op)
  // ---------------------------------------------------------------------------
  Future<void> migrateFromLegacyStorage() async {
    try {
      DebugLogger.log(
        'Starting migration from legacy storage',
        scope: 'storage/optimized',
      );
      DebugLogger.log(
        'Legacy storage migration completed',
        scope: 'storage/optimized',
      );
    } catch (error) {
      DebugLogger.log(
        'Legacy storage migration failed: $error',
        scope: 'storage/optimized',
      );
    }
  }

  Map<String, dynamic> getStorageStats() {
    return {
      'cacheSize': _cache.length,
      'cachedKeys': _cache.keys.toList(),
      'lastAccess': _cacheTimestamps.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .toList(),
    };
  }
}

List<Map<String, dynamic>> _decodeStoredJsonListWorker(
  Map<String, dynamic> payload,
) {
  final stored = payload['stored'];
  if (stored is String) {
    final decoded = jsonDecode(stored);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  if (stored is List) {
    return stored
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  return <Map<String, dynamic>>[];
}

String _encodeJsonListWorker(Map<String, dynamic> payload) {
  final raw = payload['items'] ?? payload['conversations'];
  if (raw is List) {
    return jsonEncode(raw);
  }
  if (raw is String) {
    // Already encoded.
    return raw;
  }
  return jsonEncode([]);
}
