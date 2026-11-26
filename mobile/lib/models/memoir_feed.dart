/// 与 FastAPI `/api/v1/memoirs/feed` 返回的 JSON 结构一致（`type` 区分多态）。
///
/// 统一入口：根据 [type] 解析为 [PhotoMemoir] / [TextMemoir] / [VideoMemoir]。
sealed class MemoirFeedItem {
  const MemoirFeedItem({
    required this.id,
    required this.createdAt,
  });

  final String id;
  final DateTime createdAt;

  static MemoirFeedItem fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      'photo' => PhotoMemoir.fromJson(json),
      'text' => TextMemoir.fromJson(json),
      'video' => VideoMemoir.fromJson(json),
      _ => throw FormatException('Unknown memoir card type: $type'),
    };
  }
}

final class PhotoMemoir extends MemoirFeedItem {
  const PhotoMemoir({
    required super.id,
    required super.createdAt,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
  });

  final String title;
  final String subtitle;
  final String imageUrl;

  factory PhotoMemoir.fromJson(Map<String, dynamic> json) {
    return PhotoMemoir(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      title: json['title'] as String,
      subtitle: json['subtitle'] as String? ?? '',
      imageUrl: json['image_url'] as String,
    );
  }
}

final class TextMemoir extends MemoirFeedItem {
  const TextMemoir({
    required super.id,
    required super.createdAt,
    required this.title,
    required this.body,
  });

  final String title;
  final String body;

  factory TextMemoir.fromJson(Map<String, dynamic> json) {
    return TextMemoir(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      title: json['title'] as String,
      body: json['body'] as String,
    );
  }
}

final class VideoMemoir extends MemoirFeedItem {
  const VideoMemoir({
    required super.id,
    required super.createdAt,
    required this.title,
    required this.subtitle,
    required this.posterUrl,
    required this.videoUrl,
    this.durationSeconds,
  });

  final String title;
  final String subtitle;
  final String posterUrl;
  final String videoUrl;
  final double? durationSeconds;

  factory VideoMemoir.fromJson(Map<String, dynamic> json) {
    final rawDur = json['duration_seconds'];
    double? duration;
    if (rawDur is num) {
      duration = rawDur.toDouble();
    }
    return VideoMemoir(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      title: json['title'] as String,
      subtitle: json['subtitle'] as String? ?? '',
      posterUrl: json['poster_url'] as String,
      videoUrl: json['video_url'] as String,
      durationSeconds: duration,
    );
  }
}
