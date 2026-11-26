import 'package:latlong2/latlong.dart';

/// 行程地图预览用的只读打卡点（由 [ApiClient.fetchTripCheckInPreviewPoints] 拉取）。
class CheckInPreviewPoint {
  CheckInPreviewPoint({
    required this.id,
    required this.coordinate,
    required this.time,
    required this.locationName,
    required this.note,
    this.imageUrls = const [],
  });

  final String id;
  final LatLng coordinate;
  final DateTime time;
  final String locationName;
  final String note;
  final List<String> imageUrls;

  static DateTime _parseTime(dynamic raw) {
    if (raw is String) {
      return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 将 `GET /api/trips/{id}` 中 `points` 的单条 JSON 转为模型；[imageUrls] 由调用方根据 photo id 拼接。
  factory CheckInPreviewPoint.fromTripPointJson(
    Map<String, dynamic> json, {
    required List<String> imageUrls,
  }) {
    final idVal = json['id'];
    final idStr = idVal == null ? '' : '$idVal';
    final lat = (json['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (json['longitude'] as num?)?.toDouble() ?? 0.0;
    return CheckInPreviewPoint(
      id: idStr.isEmpty ? 'unknown' : idStr,
      coordinate: LatLng(lat, lng),
      time: _parseTime(json['time']),
      locationName: (json['location_name'] as String?)?.trim() ?? '',
      note: (json['note'] as String?)?.trim() ?? '',
      imageUrls: imageUrls,
    );
  }
}
