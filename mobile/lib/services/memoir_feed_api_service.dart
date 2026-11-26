import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/memoir_feed.dart';
import 'api_client.dart';

/// 访问 `/api/v1/memoirs/feed` 的轻量 API 层（与现有 [ApiClient] 共用 baseUrl）。
class MemoirFeedApiService {
  MemoirFeedApiService({required ApiClient apiClient}) : _api = apiClient;

  final ApiClient _api;

  /// 拉取混合卡片列表；网络 / HTTP / JSON 解析错误会抛出 [MemoirFeedApiException]。
  Future<List<MemoirFeedItem>> fetchFeed() async {
    final uri = _api.buildUri('/api/v1/memoirs/feed');
    late final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 20));
    } on SocketException catch (e, st) {
      debugPrint('MemoirFeedApiService SocketException: $e\n$st');
      throw MemoirFeedApiException(
        '网络不可用，请确认设备联网且后端已启动（默认 ${_api.base}）。',
        cause: e,
      );
    } on TimeoutException catch (e, st) {
      debugPrint('MemoirFeedApiService TimeoutException: $e\n$st');
      throw MemoirFeedApiException('请求超时，请稍后重试。', cause: e);
    } on http.ClientException catch (e, st) {
      debugPrint('MemoirFeedApiService ClientException: $e\n$st');
      throw MemoirFeedApiException('网络请求失败：${e.message}', cause: e);
    } catch (e, st) {
      debugPrint('MemoirFeedApiService error: $e\n$st');
      throw MemoirFeedApiException('请求失败：$e', cause: e);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MemoirFeedApiException(
        '服务器返回 ${response.statusCode}',
        details:
            response.body.isNotEmpty ? response.body : null,
      );
    }

    final dynamic decoded;
    try {
      decoded = json.decode(response.body);
    } catch (e, st) {
      debugPrint('MemoirFeedApiService JSON decode: $e\n$st');
      throw MemoirFeedApiException('响应不是合法 JSON。', cause: e);
    }

    if (decoded is! List<dynamic>) {
      throw const MemoirFeedApiException('响应格式错误：期望 JSON 数组。');
    }

    try {
      return decoded
          .map((e) => MemoirFeedItem.fromJson(
                Map<String, dynamic>.from(e as Map),
              ))
          .toList();
    } on FormatException catch (e, st) {
      debugPrint('MemoirFeedApiService parse item: $e\n$st');
      throw MemoirFeedApiException('卡片数据解析失败：${e.message}', cause: e);
    }
  }
}

/// API 层统一异常，便于 UI 展示 SnackBar / 错误页。
class MemoirFeedApiException implements Exception {
  const MemoirFeedApiException(this.message, {this.details, this.cause});

  final String message;
  final String? details;
  final Object? cause;

  @override
  String toString() =>
      'MemoirFeedApiException($message${details != null ? ', details: $details' : ''})';
}
