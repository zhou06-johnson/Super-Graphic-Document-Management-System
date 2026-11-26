class LocationCard {
  const LocationCard({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.pointCount,
    required this.coverPhotoId,
    required this.heroCoverTag,
  });

  final int id;
  final String title;
  final DateTime createdAt;

  /// Number of check-in points (derived from backend `points` length).
  final int pointCount;

  /// Optional "cover" photo id derived from first point's `photo_ids[0]`.
  final int? coverPhotoId;

  /// Stable hero tag for the cover image.
  final String heroCoverTag;

  static int? _toIntOrNull(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static int _toInt(dynamic v, {required int defaultValue}) {
    final parsed = _toIntOrNull(v);
    return parsed ?? defaultValue;
  }

  static DateTime _parseDateTime(dynamic raw) {
    if (raw == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (raw is DateTime) return raw;
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
      return DateTime.tryParse(s) ?? DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  factory LocationCard.fromJson(Map<String, dynamic> json) {
    final pointsRaw = (json['points'] as List<dynamic>?) ?? const <dynamic>[];

    int? firstCover;
    for (final p in pointsRaw) {
      if (p is Map) {
        final photoIdsRaw =
            p['photo_ids'] ?? p['photoIds'] ?? p['photo_ids_json'];
        if (photoIdsRaw is List && photoIdsRaw.isNotEmpty) {
          final v = _toIntOrNull(photoIdsRaw.first);
          if (v != null && v > 0) {
            firstCover = v;
            break;
          }
        }
      }
    }

    return LocationCard(
      id: _toInt(json['id'], defaultValue: 0),
      title: (json['title'] as String?) ?? '',
      createdAt: _parseDateTime(json['created_at'] ?? json['createdAt']),
      pointCount: pointsRaw.length,
      coverPhotoId: (firstCover != null && firstCover > 0) ? firstCover : null,
      heroCoverTag: 'trip_cover_${json['id']}',
    );
  }
}

