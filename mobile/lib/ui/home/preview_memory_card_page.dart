import 'dart:io';

import 'package:flutter/material.dart';

import 'add_memory_card_page.dart';

class PreviewMemoryCardPage extends StatelessWidget {
  const PreviewMemoryCardPage({
    super.key,
    required this.card,
  });

  final MemoryCard card;

  static const _expandedHeight = 350.0;

  String _formatCnDate(DateTime dt) {
    return '${dt.year}年${dt.month}月${dt.day}日';
  }

  int _estimateReadingMinutes(String text) {
    final t = text.trim();
    if (t.isEmpty) return 1;

    // A pragmatic heuristic that works for both CJK and latin text:
    // - count CJK characters as "words"
    // - count latin words split by whitespace
    final cjkCount = RegExp(r'[\u4E00-\u9FFF]').allMatches(t).length;
    final latinWordCount = t.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).length;
    final tokens = (cjkCount + latinWordCount).clamp(1, 200000);

    final minutes = (tokens / 250).ceil();
    return minutes.clamp(1, 60);
  }

  DateTime _parseCreatedAt(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return DateTime.now();
    return DateTime.tryParse(v) ?? DateTime.now();
  }

  bool _isRemotePath(String p) =>
      p.startsWith('http://') || p.startsWith('https://');

  Widget _buildCoverImage(String path, {required String heroTag}) {
    final img = _isRemotePath(path)
        ? Image.network(
            path,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: Icon(Icons.photo, color: Colors.black.withOpacity(0.25)),
            ),
          )
        : Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: Icon(Icons.photo, color: Colors.black.withOpacity(0.25)),
            ),
          );

    return Hero(
      tag: heroTag,
      child: img,
    );
  }

  @override
  Widget build(BuildContext context) {
    final createdAt = _parseCreatedAt(card.createdAt);
    final createdText = _formatCnDate(createdAt);
    final readingMin = _estimateReadingMinutes(card.content);
    final imagePaths = card.imagePaths
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    // 只在最左侧小区域监听“向右滑返回”，避免抢占 PageView 的横向滑动手势。
    final bool canPop = Navigator.of(context).canPop();

    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.white,
          floatingActionButton: FloatingActionButton(
            backgroundColor: const Color(0xFF6B3DBB),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            elevation: 4,
            highlightElevation: 6,
            onPressed: () async {
              final ok = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => AddMemoryCardPage(initialCard: card),
                ),
              );
              if (ok == true && context.mounted) {
                Navigator.of(context).maybePop(true);
              }
            },
            child: const Icon(Icons.edit_rounded),
          ),
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: _expandedHeight,
                pinned: true,
                backgroundColor: Colors.white,
                elevation: 0,
                automaticallyImplyLeading: false,
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      imagePaths.isEmpty
                          ? Container(
                              color: Colors.grey.shade100,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.photo,
                                color: Colors.black.withOpacity(0.22),
                                size: 44,
                              ),
                            )
                          : PageView.builder(
                              itemCount: imagePaths.length,
                              physics: const PageScrollPhysics(),
                              itemBuilder: (_, index) {
                                final path = imagePaths[index];
                                final heroTag =
                                    'card_image_${card.id ?? 'new'}_$index';
                                return _buildCoverImage(
                                  path,
                                  heroTag: heroTag,
                                );
                              },
                            ),
                      // 纯视觉遮罩层：不要拦截触摸手势，保证 PageView 可左右滑动。
                      IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: const [0.0, 0.3, 1.0],
                              colors: [
                                Colors.black.withOpacity(0.4),
                                Colors.transparent,
                                Colors.black.withOpacity(0.3),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Transform(
                  transform: Matrix4.translationValues(0, -32, 0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(32),
                      ),
                      border: Border(
                        top: BorderSide(
                          color: Colors.grey.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 28,
                          offset: const Offset(0, -8),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 40),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            card.title.trim().isEmpty
                                ? '无题瞬间'
                                : card.title.trim(),
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                              color: Color(0xFF111111),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '$createdText · $readingMin min',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade500,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Divider(
                            height: 32,
                            thickness: 0.5,
                            color: Color(0xFFEEEEEE),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            card.content.trim(),
                            style: const TextStyle(
                              fontSize: 16,
                              height: 1.7,
                              color: Color(0xFF333333),
                            ),
                          ),
                          const SizedBox(height: 80),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),

        if (canPop)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 28,
            child: _LeftEdgePopGesture(
              onPop: () => Navigator.of(context).maybePop(),
            ),
          ),
      ],
    );
  }
}

class _LeftEdgePopGesture extends StatefulWidget {
  const _LeftEdgePopGesture({
    required this.onPop,
  });

  final VoidCallback onPop;

  @override
  State<_LeftEdgePopGesture> createState() => _LeftEdgePopGestureState();
}

class _LeftEdgePopGestureState extends State<_LeftEdgePopGesture> {
  double _dragDx = 0;
  bool _didPop = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) {
        _dragDx = 0;
        _didPop = false;
      },
      onHorizontalDragUpdate: (details) {
        _dragDx += details.delta.dx;
        if (_dragDx > 80 && !_didPop) {
          _didPop = true;
          widget.onPop();
        }
      },
      child: const SizedBox.expand(),
    );
  }
}
