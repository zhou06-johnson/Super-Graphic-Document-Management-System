import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data'; // 🚨 新增：用于 Uint8List

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/check_in_preview_point.dart';

/// 轻量封装 FastAPI 后端的 HTTP 调用。
///
/// 后续可以把 baseUrl 做成可配置（例如从设置页修改）。
///
class ApiClient {
  ApiClient({
    required this.baseUrl,
  })  : _normalizedBase = _withoutTrailingSlash(baseUrl),
        _dio = Dio(BaseOptions(baseUrl: _withoutTrailingSlash(baseUrl)));

  String baseUrl;

  /// 去除尾斜杠后的规范化 base，所有内部拼接都用此值。
  String _normalizedBase;
  final Dio _dio;

  static String _withoutTrailingSlash(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// Update all HTTP clients together after the user changes the server URL.
  void updateBaseUrl(String value) {
    final normalized = _withoutTrailingSlash(value);
    baseUrl = normalized;
    _normalizedBase = normalized;
    _dio.options.baseUrl = normalized;
  }

  Future<List<Map<String, dynamic>>> listLibraryVideos() async {
    final response = await _dio.get<List<dynamic>>('/api/ai-editor/assets/videos');
    return (response.data ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> uploadLibraryVideo(File file, String name) async {
    await _dio.post<String>(
      '/api/ai-editor/assets/videos',
      queryParameters: {'name': name},
      data: file.openRead(),
      options: Options(
        contentType: 'application/octet-stream',
        headers: {Headers.contentLengthHeader: await file.length()},
        responseType: ResponseType.plain,
      ),
    );
  }

  String libraryVideoThumbnail(String id) =>
      '$_normalizedBase/api/ai-editor/assets/$id/thumbnail';

  Future<String> getAmapLocationName(double lat, double lng) async {
    try {
      final response = await _dio.get(
        '/api/maps/regeo',
        queryParameters: {'lat': lat, 'lng': lng},
      );
      if (response.data is Map<String, dynamic>) {
        return (response.data as Map<String, dynamic>)['name'] as String? ?? '未知地点';
      }
      return '未知地点';
    } catch (e) {
      debugPrint('❌ 后端逆地理编码异常: $e');
      return '定位解析失败';
    }
  }

  Future<List<Map<String, dynamic>>> searchAmapPois(String keyword) async {
    if (keyword.trim().isEmpty) return [];
    try {
      final response = await _dio.get(
        '/api/maps/pois',
        queryParameters: {'keyword': keyword},
      );
      if (response.data is! Map<String, dynamic>) return [];
      final pois = (response.data as Map<String, dynamic>)['pois'] as List<dynamic>? ?? [];
      return pois.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (e) {
      debugPrint('❌ 后端 POI 搜索异常: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> getInputTips(String keyword) async {
    if (keyword.trim().isEmpty) return [];
    try {
      final response = await _dio.get(
        '/api/maps/inputtips',
        queryParameters: {'keywords': keyword},
      );
      final tips = response.data['tips'] as List<dynamic>? ?? [];
      return tips.map((e) => e as Map<String, dynamic>).toList();
    } catch (e) {
      debugPrint('❌ 获取输入提示失败: $e');
      return [];
    }
  }

  /// path 必须以 '/' 开头，例如 '/api/photos'
  Uri _uri(String path) {
    // 双重防护：确保 base 无尾斜杠，path 有前导斜杠
    final b = _normalizedBase.endsWith('/')
        ? _normalizedBase.substring(0, _normalizedBase.length - 1)
        : _normalizedBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$b$p');
  }

  /// 暴露给 UI 用于安全拼接完整的 Uri。
  ///
  /// - base: 自动去除尾斜杠
  /// - path: 自动补齐前导斜杠
  Uri buildUri(String path) {
    final b = _normalizedBase.endsWith('/')
        ? _normalizedBase.substring(0, _normalizedBase.length - 1)
        : _normalizedBase;
    final p = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$b$p');
  }

  /// 暴露给 UI 用于拼接图片地址等（已去除尾斜杠，可安全直接拼接 '/api/...'）。
  String get base => _normalizedBase;

  Future<Map<String, dynamic>> getJson(String path) async {
    final response = await http.get(_uri(path));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw ApiException('GET $path failed: ${response.statusCode}', response.body);
  }

  Future<List<dynamic>> getJsonList(String path) async {
    final response = await http.get(_uri(path));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return json.decode(response.body) as List<dynamic>;
    }
    throw ApiException('GET $path failed: ${response.statusCode}', response.body);
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final response = await http.post(
      _uri(path),
      headers: const {'Content-Type': 'application/json'},
      body: body == null ? null : json.encode(body),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) {
        return const {};
      }
      return json.decode(response.body) as Map<String, dynamic>;
    }
    throw ApiException('POST $path failed: ${response.statusCode}', response.body);
  }


  Future<Map<String, dynamic>> startSortingSimplified({
    required String libraryRoot,
    String? primarySort,
    String? faceMode,
    bool? maintainHierarchy,
  }) {
    final body = <String, dynamic>{
      'library_root': libraryRoot,
      if (primarySort != null) 'primary_sort': primarySort,
      if (faceMode != null) 'face_mode': faceMode,
      if (maintainHierarchy != null) 'maintain_hierarchy': maintainHierarchy,
    };

    return postJson(
      '/api/start-sorting-simplified',
      body: body,
    );
  }

  /// 人脸批量录入：上传某个人的一组照片并触发后端的人脸编码。
  ///
  /// - personName: 人物名称（如 Person A）
  /// - images: 本地文件列表（通常由 image_picker 选取后转换而来）
  Future<Map<String, dynamic>> uploadEnrollmentPerson({
    required String personName,
    required List<File> images,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    if (images.isEmpty) {
      throw ApiException('No images provided for enrollment', null);
    }

    // 先构造 MultipartFile 列表
    final multipartFiles = await Future.wait(
      images.map((file) async {
        return await MultipartFile.fromFile(file.path);
      }),
    );

    final formData = FormData();
    formData.fields.add(MapEntry('person_name', personName));
    for (final mf in multipartFiles) {
      formData.files.add(MapEntry('images', mf));
    }

    final response = await _dio.post<Map<String, dynamic>>(
      '/api/enrollment/upload-person',
      data: formData,
      onSendProgress: onSendProgress,
    );

    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 200 && statusCode < 300) {
      return response.data ?? const {};
    }

    throw ApiException(
      'POST /api/enrollment/upload-person failed: $statusCode',
      response.data?.toString(),
    );
  }

  /// 获取某个已录入人物的原始图片列表。
  ///
  /// 后端返回的数据结构示例：
  /// { "images": [ { "filename": "...", "url": "/api/enrollment/image/xxx/yyy.jpg" }, ... ] }
  Future<List<Map<String, dynamic>>> getEnrolledPersonImages(String personName) async {
    final encodedName = Uri.encodeComponent(personName);
    final data = await getJson('/api/enrolled-faces/$encodedName/images');
    final list = (data['images'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
    return list;
  }

  /// 删除整个人物（包含其所有入库图片和 AI 模型中的编码）。
  Future<Map<String, dynamic>> deleteEnrolledPerson(String personName) {
    return postJson(
      '/api/delete-enrolled-face',
      body: {'person_name': personName},
    );
  }

  /// 删除某个人物的一组入库图片，并同步更新 encodings 文件。
  Future<Map<String, dynamic>> deleteEnrolledImages(
    String personName,
    List<String> filenames,
  ) {
    return postJson(
      '/api/delete-enrolled-images',
      body: {
        'person_name': personName,
        'filenames': filenames,
      },
    );
  }

  Future<Map<String, dynamic>> createStoryCard({
    required String title,
    required String content,
    int? coverPhotoId,
    List<int>? imagePhotoIds,
    int? readingMinutes,
  }) {
    final body = <String, dynamic>{
      'title': title,
      'content': content,
      if (coverPhotoId != null) 'cover_photo_id': coverPhotoId,
      'image_photo_ids': imagePhotoIds ?? const <int>[],
      if (readingMinutes != null) 'reading_minutes': readingMinutes,
    };
    return postJson('/api/story-articles', body: body);
  }

  /// Backwards/for-UI compatibility alias.
  ///
  /// Some UI pages call this method name `createStoryArticle` while the
  /// underlying endpoint is still `/api/story-articles`.
  Future<Map<String, dynamic>> createStoryArticle({
    required String title,
    required String content,
    int? coverPhotoId,
    List<int>? imagePhotoIds,
    int? readingMinutes,
  }) {
    return createStoryCard(
      title: title,
      content: content,
      coverPhotoId: coverPhotoId,
      imagePhotoIds: imagePhotoIds,
      readingMinutes: readingMinutes,
    );
  }

  /// 创建行程（Trip），包含多个打卡点（CheckInPoint）。
  Future<Map<String, dynamic>> createTrip({
    required String title,
    required List<Map<String, dynamic>> points,
  }) async {
    final normalizedPoints = points
        .map((p) => <String, dynamic>{
              ...p,
              'coordinate_system': 'GCJ-02',
            })
        .toList();
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/trips',
      data: {
        'title': title,
        'points': normalizedPoints,
      },
    );
    return response.data ?? {};
  }

  /// 查询已落库的行程（校验 `/api/trips` 写入结果）。
  Future<Map<String, dynamic>> getTrip(int tripId) async {
    return getJson('/api/trips/$tripId');
  }

  /// 拉取某行程的打卡点列表（供地图预览页使用）。
  ///
  /// 走真实接口 `GET /api/trips/{tripId}`；解析失败或网络错误时抛出 [ApiException]。
  Future<List<CheckInPreviewPoint>> fetchTripCheckInPreviewPoints(
    int tripId,
  ) async {
    final data = await getJson('/api/trips/$tripId');
    final rawPoints = data['points'];
    if (rawPoints is! List<dynamic>) {
      return [];
    }
    final out = <CheckInPreviewPoint>[];
    for (final item in rawPoints) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final photoIds = <int>[];
      final idsRaw = m['photo_ids'];
      if (idsRaw is List<dynamic>) {
        for (final x in idsRaw) {
          final v = int.tryParse('$x');
          if (v != null && v > 0) photoIds.add(v);
        }
      }
      final imageUrls = photoIds
          .map((id) => '$_normalizedBase/api/photos/$id/file')
          .toList();
      out.add(CheckInPreviewPoint.fromTripPointJson(m, imageUrls: imageUrls));
    }
    return out;
  }

  /// 订阅整理/录入等任务的实时日志（SSE）。
  /// 返回流中每个元素为后端推送的 JSON：{ "progress": int, "message": string, "status": string, ... }
  /// 进入“执行中”页时订阅，离开时取消订阅。
  Stream<Map<String, dynamic>> streamLogs() async* {
    final client = http.Client();
    try {
      final request = http.Request('GET', _uri('/api/stream-logs'));
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw ApiException(
          'GET /api/stream-logs failed: ${response.statusCode}',
          body,
        );
      }
      String buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final parts = buffer.split('\n\n');
        buffer = parts.removeLast();
        for (final part in parts) {
          String? dataLine;
          for (final l in part.split('\n')) {
            if (l.startsWith('data:')) {
              dataLine = l;
              break;
            }
          }
          if (dataLine == null || dataLine.length <= 5) continue;
          final jsonStr = dataLine.substring(5).trim();
          if (jsonStr.isEmpty) continue;
          try {
            final data = json.decode(jsonStr) as Map<String, dynamic>;
            yield data;
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  /// 解析单图上传接口返回的 photo id（含 duplicate 命中时的 existing_id）。
  static int? photoIdFromUploadResponse(Map<String, dynamic> map) {
    if (map['duplicate'] == true) {
      final id = map['existing_id'];
      if (id is int) return id;
      if (id is num) return id.toInt();
    }
    final photo = map['photo'];
    if (photo is Map<String, dynamic>) {
      final id = photo['id'];
      if (id is int) return id;
      if (id is num) return id.toInt();
    }
    return null;
  }

  /// 逐张上传本地路径列表（内部调用 [uploadPhoto]），返回成功拿到的 photo id 列表；单张失败仅打日志并跳过。
  ///
  /// 与 [uploadPhotosBatch]（multipart 批量接口）不同，本方法适用于需按顺序解析单张响应的场景（如行程打卡）。
  Future<List<int>> uploadPhotoIdsByPaths(List<String> filePaths) async {
    final photoIds = <int>[];
    for (final path in filePaths) {
      try {
        final file = File(path);
        if (!await file.exists()) {
          debugPrint('上传图片跳过（文件不存在）: $path');
          continue;
        }
        final map = await uploadPhoto(file);
        final id = photoIdFromUploadResponse(map);
        if (id != null) photoIds.add(id);
      } catch (e) {
        debugPrint('上传图片失败: $path, 错误: $e');
      }
    }
    return photoIds;
  }

  /// 单张上传（带内容哈希查重；若重复返回 duplicate: true）。
  Future<Map<String, dynamic>> uploadPhoto(
    File file, {
    String? description,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final formData = await _photoFormData(file, description);
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/photos',
      data: formData,
      onSendProgress: onSendProgress,
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 200 && statusCode < 300) {
      return response.data ?? const {};
    }
    throw ApiException(
      'POST /api/photos failed: $statusCode',
      response.data?.toString(),
    );
  }

  /// 封面上传（与普通照片上传分离，便于后端做封面专属处理）。
  ///
  /// 后端返回示例：
  /// { "cover": { "id": 123, "url": "/api/covers/123/file" } }
  Future<Map<String, dynamic>> uploadCover(
    File file, {
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final filename = file.path.split(RegExp(r'[/\\]')).last;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        filename: filename,
        contentType: _mimeForPath(file.path),
      ),
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/api/covers',
      data: formData,
      onSendProgress: onSendProgress,
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 200 && statusCode < 300) {
      return response.data ?? const {};
    }
    throw ApiException(
      'POST /api/covers failed: $statusCode',
      response.data?.toString(),
    );
  }

  /// 批量上传：先添加未重复的，重复的仅提示不写入。返回 { added: [...], duplicates: [...] }。
  Future<Map<String, dynamic>> uploadPhotosBatch(
    List<File> files, {
    String? description,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    if (files.isEmpty) {
      return {'added': <dynamic>[], 'duplicates': <dynamic>[]};
    }

    final formData = FormData();
    if (description != null && description.trim().isNotEmpty) {
      formData.fields.add(MapEntry('description', description.trim()));
    }
    for (final file in files) {
      final mime = _mimeForPath(file.path);
      final filename = file.path.split(RegExp(r'[/\\]')).last;
      formData.files.add(
        MapEntry(
          'files',
          await MultipartFile.fromFile(
            file.path,
            filename: filename,
            contentType: mime,
          ),
        ),
      );
    }

    final response = await _dio.post<Map<String, dynamic>>(
      '/api/photos/batch',
      data: formData,
      onSendProgress: onSendProgress,
    );
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 200 && statusCode < 300) {
      final data = response.data ?? <String, dynamic>{};
      return {
        'added': data['added'] is List ? data['added'] as List : <dynamic>[],
        'duplicates': data['duplicates'] is List ? data['duplicates'] as List : <dynamic>[],
      };
    }
    throw ApiException(
      'POST /api/photos/batch failed: $statusCode',
      response.data?.toString(),
    );
  }

  Future<Map<String, dynamic>> getPhotoEnhanced(int photoId) async {
    return getJson('/api/photos/$photoId/enhanced');
  }

  /// PATCH `/api/photos/{photo_id}/enhanced`
  Future<Map<String, dynamic>> patchPhotoEnhanced(
    int photoId, {
    List<String>? personNames,
    DateTime? takenAt,
    String? location,
    String? description,
  }) async {
    final payload = <String, dynamic>{};
    if (personNames != null) {
      payload['person_names'] = personNames;
    }
    if (takenAt != null) {
      payload['taken_at'] = takenAt.toIso8601String();
    }
    if (location != null) {
      payload['location'] = location;
    }
    if (description != null) {
      payload['description'] = description;
    }

    final response = await http.patch(
      _uri('/api/photos/$photoId/enhanced'),
      headers: const {'Content-Type': 'application/json'},
      body: json.encode(payload),
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return const {};
      return json.decode(response.body) as Map<String, dynamic>;
    }

    throw ApiException(
      'PATCH /api/photos/$photoId/enhanced failed: ${response.statusCode}',
      response.body,
    );
  }

  static MediaType? _mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return MediaType('image', 'jpeg');
    if (lower.endsWith('.png')) return MediaType('image', 'png');
    if (lower.endsWith('.gif')) return MediaType('image', 'gif');
    if (lower.endsWith('.webp')) return MediaType('image', 'webp');
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return MediaType('image', 'heic');
    return null;
  }

  Future<FormData> _photoFormData(File file, String? description) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        contentType: _mimeForPath(file.path),
      ),
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });
    return formData;
  }

  /// Bot 对话：请求后端代理 SiliconFlow chat/completions，返回助手回复内容。
  /// [messages] 为历史消息列表，每项含 role（user/assistant）与 content。
  /// [personContext] 可选，当前聚焦的人物名，用于后端增强 prompt。
  Future<BotChatResult> botChat(
    List<Map<String, String>> messages, {
    String? personContext,
  }) async {
    final body = <String, dynamic>{
      'messages': messages,
      if (personContext != null && personContext.isNotEmpty) 'person_context': personContext,
    };
    final data = await postJson('/api/ai/chat', body: body);
    final content = data['content'] as String? ?? '';
    final rawPhotos = data['photos'];
    final photos = <BotChatPhoto>[];
    if (rawPhotos is List) {
      for (final p in rawPhotos) {
        if (p is Map<String, dynamic>) {
          photos.add(BotChatPhoto.fromJson(p));
        } else if (p is Map) {
          photos.add(BotChatPhoto.fromJson(Map<String, dynamic>.from(p)));
        }
      }
    }
    return BotChatResult(content: content, photos: photos);
  }

  Future<void> delete(String path) async {
    final response = await http.delete(_uri(path));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('DELETE $path failed: ${response.statusCode}', response.body);
    }
  }

  // =========================================================================
  // 🚨 修复：兼容 Web 和移动端的图片上传方法（基于字节流 Uint8List，移到了类内部）
  // =========================================================================
  
  /// 上传单张封面图（兼容 Web）
  Future<Map<String, dynamic>> uploadCoverFromBytes(
    Uint8List bytes,
    String filename, {
    void Function(int, int)? onSendProgress,
  }) async {
    final uri = Uri.parse('$base/api/covers');
    final request = http.MultipartRequest('POST', uri);

    request.files.add(
      http.MultipartFile.fromBytes(
        'file', 
        bytes,
        filename: filename,
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('封面图上传失败: ${response.statusCode} ${response.body}');
    }
  }

  /// 批量上传图片（兼容 Web）
  Future<Map<String, dynamic>> uploadPhotosBatchFromBytes(
    List<Uint8List> bytesList,
    List<String> filenames, {
    void Function(int, int)? onSendProgress,
  }) async {
    final uri = Uri.parse('$base/api/photos/batch');
    final request = http.MultipartRequest('POST', uri);

    for (int i = 0; i < bytesList.length; i++) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'files', 
          bytesList[i],
          filename: filenames[i],
        ),
      );
    }

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } else {
      throw Exception('批量图片上传失败: ${response.statusCode} ${response.body}');
    }
  }
}

class BotChatResult {
  const BotChatResult({
    required this.content,
    this.photos = const [],
  });

  final String content;
  final List<BotChatPhoto> photos;
}

class BotChatPhoto {
  const BotChatPhoto({
    required this.id,
    required this.url,
    this.description,
  });

  factory BotChatPhoto.fromJson(Map<String, dynamic> json) {
    return BotChatPhoto(
      id: (json['id'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
      description: json['description'] as String?,
    );
  }

  final int id;
  final String url;
  final String? description;
}

class ApiException implements Exception {
  ApiException(this.message, [this.details]);

  final String message;
  final String? details;

  @override
  String toString() => 'ApiException($message, details: $details)';
}

/// 后端 SSE 推送的一条状态（进度/日志）。
class StreamLogEntry {
  StreamLogEntry({
    required this.progress,
    required this.message,
    required this.status,
    this.source,
    this.analytics,
  });

  factory StreamLogEntry.fromJson(Map<String, dynamic> json) {
    return StreamLogEntry(
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      message: json['message'] as String? ?? '',
      status: json['status'] as String? ?? 'running',
      source: json['source'] as String?,
      analytics: json['analytics'] as Map<String, dynamic>?,
    );
  }

  final int progress;
  final String message;
  final String status;
  final String? source;
  final Map<String, dynamic>? analytics;
}