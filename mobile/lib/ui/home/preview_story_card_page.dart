import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/story_card.dart';
import '../../services/api_client.dart';

class PreviewStoryCardPage extends StatelessWidget {
  const PreviewStoryCardPage({
    super.key,
    required this.card,
  });

  final StoryCard card;

  String _formatMeta() {
    final minutes = card.readingMinutes <= 0 ? 1 : card.readingMinutes;
    final created = card.createdAt;
    final dateStr =
        '${created.year.toString().padLeft(4, '0')}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}';
    return '$minutes min · 故事 · $dateStr';
  }

  List<Widget> _buildParsedContent(BuildContext context) {
    final theme = Theme.of(context);
    final api = context.read<ApiClient>();
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 16,
      height: 1.8,
      color: Colors.black.withOpacity(0.9),
    );

    final spacing = const SizedBox(height: 18);
    final widgets = <Widget>[];
    final content = card.content.trim();
    if (content.isEmpty) return widgets;

    final reg = RegExp(r'\[IMG_(\d+)\]');
    int cursor = 0;

    void addTextSegment(String text) {
      final t = text.trim();
      if (t.isEmpty) return;
      widgets.add(
        Text(
          t,
          style: textStyle,
        ),
      );
      widgets.add(spacing);
    }

    for (final m in reg.allMatches(content)) {
      if (m.start > cursor) {
        addTextSegment(content.substring(cursor, m.start));
      }

      final rawIndex = m.group(1);
      final idx = rawIndex == null ? null : int.tryParse(rawIndex);
      if (idx != null &&
          idx >= 0 &&
          idx < card.imagePhotoIds.length) {
        final photoId = card.imagePhotoIds[idx];
        final url = '${api.base}/api/photos/$photoId/file';
        widgets.add(
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.grey.shade300,
                  alignment: Alignment.center,
                  child: const Icon(Icons.broken_image, color: Colors.white70),
                ),
              ),
            ),
          ),
        );
        widgets.add(spacing);
      }

      cursor = m.end;
    }

    if (cursor < content.length) {
      addTextSegment(content.substring(cursor));
    }

    if (widgets.isNotEmpty && widgets.last is SizedBox) {
      widgets.removeLast();
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = card.coverPhotoId != null;
    String? coverUrl;
    if (hasCover) {
      final api = context.read<ApiClient>();
      // 后端封面图片与普通照片统一通过 /api/photos/{id}/file 暴露
      coverUrl = '${api.base}/api/photos/${card.coverPhotoId}/file';
    }

    final meta = _formatMeta();

    return Scaffold(
      backgroundColor: const Color(0xFFF9F7FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        titleSpacing: 0,
        centerTitle: false,
        title: Text(
          '故事详情',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxWidth = constraints.maxWidth;
            final isWide = maxWidth >= 700;
            final horizontalPadding = isWide ? (maxWidth - 640) / 2 : 20.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                24,
                horizontalPadding,
                32,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasCover && coverUrl != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Image.network(
                          coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.grey.shade300,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.broken_image,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  Text(
                    card.title.trim().isEmpty
                        ? '无题故事'
                        : card.title.trim(),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontSize: 28,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      color: Colors.black87,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    meta,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withOpacity(0.5),
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ..._buildParsedContent(context),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
