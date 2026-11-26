class StoryCard {
  const StoryCard({
    required this.id,
    required this.title,
    required this.content,
    required this.coverPhotoId,
    required this.imagePhotoIds,
    required this.readingMinutes,
    required this.createdAt,
  });

  /// Backend `StoryArticleRead.id`.
  final int id;

  final String title;
  final String content;

  /// Backend `cover_photo_id` (nullable).
  final int? coverPhotoId;

  /// Backend `image_photo_ids` (never null).
  final List<int> imagePhotoIds;

  /// Backend `reading_minutes`.
  final int readingMinutes;

  final DateTime createdAt;

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

  static List<int> _toIntList(dynamic v) {
    if (v is! List) return const <int>[];
    final out = <int>[];
    for (final x in v) {
      final t = _toIntOrNull(x);
      if (t != null) out.add(t);
    }
    return out;
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

  factory StoryCard.fromJson(Map<String, dynamic> json) {
    final coverRaw = json['cover_photo_id'] ?? json['coverPhotoId'];
    final cover = _toIntOrNull(coverRaw);
    final imageIdsRaw = json['image_photo_ids'] ?? json['imagePhotoIds'];

    final readingRaw = json['reading_minutes'] ?? json['readingMinutes'];
    final createdRaw = json['created_at'] ?? json['createdAt'];

    return StoryCard(
      id: _toInt(json['id'], defaultValue: 0),
      title: (json['title'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
      coverPhotoId: (cover != null && cover > 0) ? cover : null,
      imagePhotoIds: _toIntList(imageIdsRaw).where((e) => e > 0).toList(),
      readingMinutes: _toInt(readingRaw, defaultValue: 1),
      createdAt: _parseDateTime(createdRaw),
    );
  }
}

