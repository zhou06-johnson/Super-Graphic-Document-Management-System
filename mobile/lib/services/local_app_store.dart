import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'; // 🚨 引入 kIsWeb
import 'package:path_provider/path_provider.dart';

/// Small persistent store for app settings and the most recent home response.
///
/// It intentionally stores JSON metadata only. Photos and other large files stay
/// in the server library and are not copied into the preferences file.
class LocalAppStore {
  static const _apiBaseUrlKey = 'apiBaseUrl';
  static const _homeSnapshotKey = 'homeSnapshot';

  Map<String, dynamic> _data = <String, dynamic>{};
  Future<void>? _initializing;
  Future<void> _writeQueue = Future<void>.value();

  Future<void> initialize() => _initializing ??= _readFromDisk();

  Future<void> _readFromDisk() async {
    // 🚨 Web 端不支持本地文件系统，直接跳过读取
    if (kIsWeb) return;

    try {
      final file = await _storeFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        _data = Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      // A damaged cache must never prevent the app from opening.
      _data = <String, dynamic>{};
    } on FileSystemException {
      _data = <String, dynamic>{};
    } catch (_) {
      // This includes a missing native plugin in tests; use an empty store.
      _data = <String, dynamic>{};
    }
  }

  Future<File> _storeFile() async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}/memoirscore-local.json');
  }

  Future<void> _persist() async {
    // 🚨 Web 端直接跳过写入，防止 MissingPluginException
    if (kIsWeb) return;

    final snapshot = jsonEncode(_data);
    final file = await _storeFile();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(snapshot, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _setValue(String key, Object? value) async {
    await initialize();
    final write = _writeQueue.then((_) async {
      _data[key] = value;
      await _persist();
    });
    _writeQueue = write.catchError((Object _) {});
    await write;
  }

  Future<String?> readApiBaseUrl() async {
    await initialize();
    final value = _data[_apiBaseUrlKey];
    return value is String ? value : null;
  }

  Future<void> saveApiBaseUrl(String value) =>
      _setValue(_apiBaseUrlKey, value);

  Future<Map<String, dynamic>?> readHomeSnapshot() async {
    await initialize();
    final value = _data[_homeSnapshotKey];
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  Future<void> saveHomeSnapshot({
    required List<dynamic> memories,
    required List<dynamic> stories,
    required List<dynamic> trips,
  }) async {
    final snapshot = <String, dynamic>{
      'memories': memories,
      'stories': stories,
      'trips': trips,
      'savedAt': DateTime.now().toIso8601String(),
    };
    // UserDefaults/file preferences are for small records, not an image store.
    if (jsonEncode(snapshot).length > 2 * 1024 * 1024) return;
    await _setValue(_homeSnapshotKey, snapshot);
  }
}