import 'dart:io';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';
import 'add_memory_card_page.dart';
import 'add_story_card_page.dart';
import 'add_location_card_page.dart';
import '../../services/api_client.dart';
import '../../services/local_app_store.dart';
import '../settings_page.dart';
import 'preview_memory_card_page.dart';
import '../../models/story_card.dart';
import '../../models/location_card.dart';
import 'preview_location_card_page.dart';
import 'preview_story_card_page.dart';
import '../compo_wave_background.dart';

/// 首页液态玻璃 [BackdropFilter] 统一模糊半径（sigma）。
const double _kGlassBackdropBlur = 18.0;

/// 顶部标题区「乳白」底色（与渐变透明度相乘）。
const Color _kMilkyHeaderBase = Color(0xFFF7F5F2);

class _GlassCardWrapper extends StatelessWidget {
  const _GlassCardWrapper({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    const radius = 8.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 32,
                spreadRadius: -5,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: _kGlassBackdropBlur,
                sigmaY: _kGlassBackdropBlur,
              ),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.12),
                      Colors.white.withValues(alpha: 0.04),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _pageHPad = 12.0;

  List<dynamic> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchHomeData();
  }

  int _estimateReadingMinutes(String text) {
    final t = text.trim();
    if (t.isEmpty) return 1;

    final cjkCount = RegExp(r'[\u4E00-\u9FFF]').allMatches(t).length;
    final latinWordCount =
        t.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).length;
    final tokens = (cjkCount + latinWordCount).clamp(1, 200000);

    final minutes = (tokens / 250).ceil();
    return minutes.clamp(1, 60);
  }

  Future<void> _fetchHomeData() async {
    if (!mounted) return;
    if (_items.isEmpty) setState(() => _isLoading = true);

    final localStore = context.read<LocalAppStore>();
    Map<String, dynamic>? cached;
    try {
      cached = await localStore.readHomeSnapshot();
    } catch (e) {
      debugPrint('读取首页缓存失败：$e');
    }
    if (cached != null && mounted && _items.isEmpty) {
      try {
        _showHomeSnapshot(cached);
      } catch (e) {
        debugPrint('首页缓存格式无效：$e');
      }
    }

    try {
      final api = context.read<ApiClient>();
      final results = await Future.wait([
        api.getJsonList('/api/memory-cards'),
        api.getJsonList('/api/story-articles'),
        api.getJsonList('/api/trips'),
      ]);
      try {
        await localStore.saveHomeSnapshot(
          memories: results[0],
          stories: results[1],
          trips: results[2],
        );
      } catch (e) {
        debugPrint('保存首页缓存失败：$e');
      }
      if (mounted) _showHomeSnapshot({
        'memories': results[0],
        'stories': results[1],
        'trips': results[2],
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      final hasCache = cached != null || _items.isNotEmpty;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(hasCache ? '网络不可用，正在显示本地缓存。' : '加载首页数据失败：$e'),
        ),
      );
    }
  }

  Future<void> _openVideoEditor() async {
    const channel = MethodChannel('memoirscore/video_editor');
    try {
      await channel.invokeMethod<void>('open', {
        'baseUrl': context.read<ApiClient>().baseUrl,
      });
    } on MissingPluginException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前版本无法打开视频剪辑。')),
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? '暂时无法打开视频剪辑。')),
      );
    }
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      CupertinoPageRoute<bool>(builder: (_) => const SettingsPage()),
    );
    if (changed == true && mounted) await _fetchHomeData();
  }

  void _showHomeSnapshot(Map<String, dynamic> snapshot) {
    final memoryJson = snapshot['memories'] as List<dynamic>? ?? const [];
    final storyJson = snapshot['stories'] as List<dynamic>? ?? const [];
    final tripsJson = snapshot['trips'] as List<dynamic>? ?? const [];

      final memoryCards = <MemoryCard>[];
      for (final item in memoryJson) {
        if (item is Map<String, dynamic>) {
          memoryCards.add(MemoryCard.fromJson(item));
        } else if (item is Map) {
          memoryCards.add(MemoryCard.fromJson(item.cast<String, dynamic>()));
        }
      }

      final storyCards = <StoryCard>[];
      for (final item in storyJson) {
        if (item is Map<String, dynamic>) {
          storyCards.add(StoryCard.fromJson(item));
        } else if (item is Map) {
          storyCards.add(StoryCard.fromJson(item.cast<String, dynamic>()));
        }
      }

      final locationCards = <LocationCard>[];
      for (final item in tripsJson) {
        if (item is Map<String, dynamic>) {
          locationCards.add(LocationCard.fromJson(item));
        } else if (item is Map) {
          locationCards.add(LocationCard.fromJson(item.cast<String, dynamic>()));
        }
      }

      final combined = <dynamic>[];
      combined
        ..addAll(memoryCards)
        ..addAll(storyCards)
        ..addAll(locationCards);

      DateTime _createdAtOf(dynamic item) {
        if (item is MemoryCard) {
          final raw = item.createdAt;
          if (raw == null || raw.isEmpty) {
            return DateTime.fromMillisecondsSinceEpoch(0);
          }
          try {
            return DateTime.parse(raw);
          } catch (_) {
            return DateTime.fromMillisecondsSinceEpoch(0);
          }
        }
        if (item is StoryCard) {
          return item.createdAt;
        }
        if (item is LocationCard) {
          return item.createdAt;
        }
        return DateTime.fromMillisecondsSinceEpoch(0);
      }

      combined.sort(
        (a, b) => _createdAtOf(b).compareTo(_createdAtOf(a)),
      );

      setState(() {
        _items = combined;
        _isLoading = false;
      });
  }

  String _cardTypeLabel(dynamic item) {
    if (item is MemoryCard) return '回忆';
    if (item is StoryCard) return '故事';
    if (item is LocationCard) return '行程';
    return '内容';
  }

  Future<void> _maybeDeleteCard(BuildContext context, dynamic item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除卡片'),
        content: Text(
          '确定删除这条${_cardTypeLabel(item)}吗？此操作不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _deleteCardFromServer(item);
  }

  Future<void> _deleteCardFromServer(dynamic item) async {
    final api = context.read<ApiClient>();
    try {
      if (item is MemoryCard) {
        final id = item.id;
        if (id == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('无法删除：缺少卡片 ID')),
            );
          }
          return;
        }
        await api.delete('/api/memory-cards/$id');
      } else if (item is StoryCard) {
        await api.delete('/api/story-articles/${item.id}');
      } else if (item is LocationCard) {
        await api.delete('/api/trips/${item.id}');
      } else {
        return;
      }
      if (!mounted) return;
      await _fetchHomeData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已删除')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: CompoWaveBackground(
          child: Stack(
            children: [
              CustomScrollView(
              // Content scrolls "behind" the fixed glass header.
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    _pageHPad,
                    MediaQuery.of(context).padding.top + 70,
                    _pageHPad,
                    12,
                  ),
                  sliver: _isLoading
                      ? const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.only(top: 40),
                            child: Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                        )
                      : _items.isEmpty
                          ? SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 48),
                                child: Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.style_outlined,
                                        size: 44,
                                        color: Colors.black.withOpacity(0.25),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        '还没有内容',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                              color: Colors.black87,
                                            ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '点击右下角 + 号开始记录第一条内容。',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Colors.black
                                                  .withOpacity(0.55),
                                              height: 1.4,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                            ),
                            )
                          : SliverMasonryGrid.count(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childCount: _items.length,
                              itemBuilder: (context, index) {
                                final item = _items[index];
                                if (item is MemoryCard) {
                                  final card = item;
                                  return GestureDetector(
                                    onLongPress: () =>
                                        _maybeDeleteCard(context, item),
                                    behavior: HitTestBehavior.opaque,
                                    child: MemoryCardWaterfallItem(
                                      card: card,
                                      estimateReadingMinutes:
                                          _estimateReadingMinutes,
                                      onTap: () {
                                        Navigator.of(context)
                                            .push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                PreviewMemoryCardPage(
                                                    card: card),
                                          ),
                                        )
                                            .then((_) => _fetchHomeData());
                                      },
                                    ),
                                  );
                                }
                                if (item is StoryCard) {
                                  final card = item;
                                  return GestureDetector(
                                    onLongPress: () =>
                                        _maybeDeleteCard(context, item),
                                    behavior: HitTestBehavior.opaque,
                                    child: StoryCardWaterfallItem(
                                      card: card,
                                    ),
                                  );
                                }
                                if (item is LocationCard) {
                                  final locationCard = item;
                                  return GestureDetector(
                                    onLongPress: () =>
                                        _maybeDeleteCard(context, item),
                                    behavior: HitTestBehavior.opaque,
                                    child: LocationCardWaterfallItem(
                                      locationCard: locationCard,
                                      onTap: () {
                                        Navigator.of(context)
                                            .push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                PreviewLocationCardPage(
                                                    locationCard:
                                                        locationCard),
                                          ),
                                        )
                                            .then((_) => _fetchHomeData());
                                      },
                                    ),
                                  );
                                }
                                return const SizedBox.shrink();
                              },
                            ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
            // Liquid glass header overlay
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _LiquidGlassHeader(
                onSettings: _openSettings,
                onVideoEditor: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
                    ? _openVideoEditor
                    : null,
              ),
            ),
            // Liquid glass bottom overlay（与 header 渐变方向相反）
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _LiquidGlassBottom(),
            ),
            // Floating action button with liquid glass effect.
            Positioned(
              right: 20,
              bottom: 96, // 留出底部玻璃 TabBar 的空间，避免遮挡
              child: _GlassFab(
                onPressed: () => _showAddBottomSheet(
                  context,
                  onMemoryCardsChanged: _fetchHomeData,
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _GlassFab extends StatelessWidget {
  const _GlassFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: _kGlassBackdropBlur,
          sigmaY: _kGlassBackdropBlur,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 16,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(
                Icons.add,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidGlassHeader extends StatelessWidget {
  const _LiquidGlassHeader({required this.onSettings, this.onVideoEditor});

  final VoidCallback? onVideoEditor;

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const double fadeHeight = 130.0;

    return ClipRect(
      child: ShaderMask(
        shaderCallback: (bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0.0, 0.65, 1.0], 
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _kGlassBackdropBlur,
            sigmaY: _kGlassBackdropBlur,
          ),
          child: Container(
            height: fadeHeight,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _kMilkyHeaderBase.withValues(alpha: 1.0),
                  _kMilkyHeaderBase.withValues(alpha: 0.6),
                  _kMilkyHeaderBase.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 16, top: 8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'MemoirsCore',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      if (onVideoEditor != null) const Spacer(),
                      if (onVideoEditor != null)
                        CupertinoButton(
                          padding: const EdgeInsets.all(10),
                          onPressed: onVideoEditor,
                          child: const Tooltip(
                            message: '视频剪辑',
                            child: Icon(
                              Icons.video_camera_back_outlined,
                              color: Color(0xFF30343B),
                              size: 22,
                            ),
                          ),
                        ),
                      CupertinoButton(
                        padding: const EdgeInsets.all(10),
                        onPressed: onSettings,
                        child: const Icon(
                          CupertinoIcons.gear,
                          color: Color(0xFF30343B),
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showAddBottomSheet(
  BuildContext rootContext, {
  required Future<void> Function() onMemoryCardsChanged,
}) {
  showModalBottomSheet<void>(
    context: rootContext,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.12),
    useSafeArea: true,
    builder: (sheetContext) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16, left: 16, right: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: _kGlassBackdropBlur,
              sigmaY: _kGlassBackdropBlur,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '添加内容',
                        style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.close_rounded,
                          color: Colors.black.withOpacity(0.6),
                        ),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '选择你想记录的方式，让回忆落地成卡片。',
                    style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                          color: Colors.black.withOpacity(0.65),
                        ),
                  ),
                  const SizedBox(height: 16),
                  _BottomSheetActionTile(
                    icon: Icons.style_rounded,
                    label: '添加回忆卡片',
                    description: '创建左侧那种带 Tag 的瀑布流卡片。',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final result = await Navigator.of(rootContext).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const AddMemoryCardPage(),
                        ),
                      );
                      if (result == true) {
                        await onMemoryCardsChanged();
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  _BottomSheetActionTile(
                    icon: Icons.article_rounded,
                    label: '添加故事文章',
                    description: '右上方带标题、简介和“查看”按钮的故事卡片。',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final result = await Navigator.of(rootContext).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => const AddStoryCardPage(),
                        ),
                      );
                      if (result == true) {
                        await onMemoryCardsChanged();
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                  _BottomSheetActionTile(
                    icon: Icons.location_on_rounded,
                    label: '添加位置卡片',
                    description: '带“附近”标签的全景图位置卡片。',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      final result = await Navigator.of(rootContext)
                          .push<bool>(buildAddLocationCardRoute<bool>());
                      if (result == true) {
                        await onMemoryCardsChanged();
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _BottomSheetActionTile extends StatelessWidget {
  const _BottomSheetActionTile({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withOpacity(0.14),
          border: Border.all(
            color: Colors.white.withOpacity(0.45),
            width: 0.9,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.28),
              ),
              child: Icon(
                icon,
                size: 20,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.black.withOpacity(0.6),
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.black.withOpacity(0.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiquidGlassBottom extends StatelessWidget {
  const _LiquidGlassBottom();

  @override
  Widget build(BuildContext context) {
    const double fadeHeight = 120.0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ClipRect(
        child: ShaderMask(
        shaderCallback: (bounds) {
          return const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black, Colors.black],
            stops: [0.0, 0.35, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _kGlassBackdropBlur,
            sigmaY: _kGlassBackdropBlur,
          ),
          child: Container(
            height: fadeHeight,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.12),
                  Colors.white.withValues(alpha: 0.20),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
              border: Border(
                top: BorderSide(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

typedef EstimateReadingMinutes = int Function(String text);

class MemoryCardWaterfallItem extends StatelessWidget {
  const MemoryCardWaterfallItem({
    super.key,
    required this.card,
    required this.onTap,
    required this.estimateReadingMinutes,
  });

  final MemoryCard card;
  final VoidCallback onTap;
  final EstimateReadingMinutes estimateReadingMinutes;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();
    final title = card.title.trim().isEmpty ? '无题' : card.title.trim();
    final minutes = estimateReadingMinutes(card.content);
    final meta = '$minutes min · 回忆';
    final raw = card.content.trim();
    final excerpt = raw.length <= 200 ? raw : '${raw.substring(0, 200)}…';
    final metaLine =
        card.imagePaths.isNotEmpty ? '$meta · 含配图' : meta;
    final body = excerpt.isEmpty ? metaLine : '$metaLine\n\n$excerpt';
    
    // 🚨 核心修复：如果后端返回的是相对路径，手动拼上 api.base
    String imageRef = card.imagePaths.isNotEmpty ? card.imagePaths.first.trim() : '';
    if (imageRef.startsWith('/')) {
      imageRef = '${api.base}$imageRef';
    }

    return _GlassMemoryCard(
      title: title,
      body: body,
      imageUrl: imageRef,
      onTap: onTap,
    );
  }
}

class StoryCardWaterfallItem extends StatelessWidget {
  const StoryCardWaterfallItem({
    super.key,
    required this.card,
  });

  final StoryCard card;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();

    String? coverUrl;
    if (card.coverPhotoId != null) {
      coverUrl = '${api.base}/api/photos/${card.coverPhotoId}/file';
    } else if (card.imagePhotoIds.isNotEmpty) {
      coverUrl = '${api.base}/api/photos/${card.imagePhotoIds.first}/file';
    }

    final minutes = card.readingMinutes <= 0 ? 1 : card.readingMinutes;
    final meta = '$minutes min · 故事';
    final displayTitle = card.title.trim().isEmpty
        ? '无题故事'
        : card.title.trim();

    void openDetail() {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreviewStoryCardPage(card: card),
        ),
      );
    }

    return _GlassStoryCard(
      title: displayTitle,
      subtitle: meta,
      imageUrl: coverUrl ?? '',
      onTap: openDetail,
    );
  }
}

class LocationCardWaterfallItem extends StatelessWidget {
  const LocationCardWaterfallItem({
    super.key,
    required this.locationCard,
    required this.onTap,
  });

  final LocationCard locationCard;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final api = context.read<ApiClient>();

    String? coverUrl;
    if (locationCard.coverPhotoId != null) {
      coverUrl = '${api.base}/api/photos/${locationCard.coverPhotoId}/file';
    }

    final meta = locationCard.pointCount <= 0
        ? '行程'
        : '${locationCard.pointCount} 个打卡点 · 行程';
    final displayTitle =
        locationCard.title.trim().isEmpty ? '未命名行程' : locationCard.title.trim();

    return _GlassLocationCard(
      title: displayTitle,
      subtitle: meta,
      imageUrl: coverUrl ?? '',
      onTap: onTap,
      showPlayOverlay: false,
      // 🚨 核心修复：直接设为 null 彻底禁用 Hero 动画，解决重复 tag 崩溃问题
      heroTag: null, 
    );
  }
}

/// 首页瀑布流 · 故事卡（上图下文，白底信息区）。
class _GlassStoryCard extends StatelessWidget {
  const _GlassStoryCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String imageUrl;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl.trim();
    final displayTitle = title.trim().isEmpty ? '无题' : title.trim();

    return _GlassCardWrapper(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: _glassStoryCover(url),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayTitle,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black54,
                    height: 1.4,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 首页瀑布流 · 回忆卡（全图 + 底部渐变遮罩）。
class _GlassMemoryCard extends StatefulWidget {
  const _GlassMemoryCard({
    required this.title,
    required this.body,
    required this.imageUrl,
    this.onTap,
  });

  final String title;
  final String body;
  final String imageUrl;
  final VoidCallback? onTap;

  @override
  State<_GlassMemoryCard> createState() => _GlassMemoryCardState();
}

class _GlassMemoryCardState extends State<_GlassMemoryCard> {
  PaletteGenerator? _palette;

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  @override
  void didUpdateWidget(covariant _GlassMemoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _loadPalette();
    }
  }

  Future<void> _loadPalette() async {
    final ref = widget.imageUrl.trim();
    if (ref.isEmpty) {
      if (mounted) setState(() => _palette = null);
      return;
    }
    ImageProvider? provider;
    
    if (ref.startsWith('http://') || ref.startsWith('https://') || ref.startsWith('data:image') || kIsWeb) {
      provider = NetworkImage(ref);
    } else {
      provider = FileImage(File(ref));
    }
    
    try {
      final gen = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(120, 120),
        maximumColorCount: 12,
      );
      if (mounted) setState(() => _palette = gen);
    } catch (_) {
      if (mounted) setState(() => _palette = null);
    }
  }

  Color? _seedFromPalette() {
    final p = _palette;
    if (p == null) return null;
    return p.dominantColor?.color ??
        p.vibrantColor?.color ??
        p.mutedColor?.color ??
        p.darkVibrantColor?.color;
  }

  List<Color> _bottomGradientColors() {
    final seed = _seedFromPalette();
    if (seed == null) {
      return [
        Colors.black.withValues(alpha: 0.78),
        Colors.black.withValues(alpha: 0.0),
      ];
    }
    final bottom = Color.lerp(seed, Colors.black, 0.52)!;
    final mid = Color.lerp(seed, Colors.black, 0.22)!;
    return [
      bottom.withValues(alpha: 0.9),
      mid.withValues(alpha: 0.45),
      seed.withValues(alpha: 0.0),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final displayTitle = widget.title.trim().isEmpty ? '无题' : widget.title.trim();
    final hasPhotoTint = _seedFromPalette() != null;

    return _GlassCardWrapper(
      onTap: widget.onTap,
      child: AspectRatio(
        aspectRatio: 0.65,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _glassMemoryCover(widget.imageUrl.trim()),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: _bottomGradientColors(),
                    stops: hasPhotoTint ? const [0.0, 0.45, 1.0] : null,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.body,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        height: 1.4,
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _glassStoryCover(String url) {
  if (url.isEmpty) {
    return Container(
      color: Colors.black.withValues(alpha: 0.06),
      alignment: Alignment.center,
      child: Icon(
        Icons.article_outlined,
        size: 48,
        color: Colors.black.withValues(alpha: 0.22),
      ),
    );
  }
  return Image.network(
    url,
    fit: BoxFit.cover,
    errorBuilder: (context, error, stackTrace) => Container(
      color: Colors.grey.shade300,
      alignment: Alignment.center,
      child: const Icon(Icons.photo, color: Colors.white70),
    ),
  );
}

Widget _glassMemoryCover(String ref) {
  if (ref.isEmpty) {
    return Container(
      color: Colors.black.withValues(alpha: 0.2),
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, size: 48, color: Colors.white54),
    );
  }
  
  if (ref.startsWith('http://') || ref.startsWith('https://') || ref.startsWith('data:image') || kIsWeb) {
    return Image.network(
      ref,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        color: Colors.grey.shade800,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image, color: Colors.white54),
      ),
    );
  }
  
  return Image.file(
    File(ref),
    fit: BoxFit.cover,
    errorBuilder: (context, error, stackTrace) => Container(
      color: Colors.grey.shade800,
      alignment: Alignment.center,
      child: const Icon(Icons.broken_image, color: Colors.white54),
    ),
  );
}

/// 首页瀑布流 · 行程海报液态玻璃卡（可选 Hero / 播放叠加）。
class _GlassLocationCard extends StatelessWidget {
  const _GlassLocationCard({
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    this.onTap,
    this.showPlayOverlay = true,
    this.heroTag,
  });

  final String title;
  final String subtitle;
  final String imageUrl;
  final VoidCallback? onTap;
  final bool showPlayOverlay;
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = imageUrl.trim();

    Widget imageLayer = url.isEmpty
        ? Container(
            color: Colors.black.withValues(alpha: 0.04),
            alignment: Alignment.center,
            child: Icon(
              Icons.map_outlined,
              color: Colors.black.withValues(alpha: 0.22),
            ),
          )
        : Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              color: Colors.grey.shade300,
              alignment: Alignment.center,
              child: const Icon(Icons.photo, color: Colors.white70),
            ),
          );

    if (heroTag != null) {
      imageLayer = Hero(
        tag: heroTag!,
        child: Material(
          color: Colors.transparent,
          child: imageLayer,
        ),
      );
    }

    return _GlassCardWrapper(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  imageLayer,
                  if (showPlayOverlay)
                    Center(
                      child: ClipOval(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: _kGlassBackdropBlur,
                            sigmaY: _kGlassBackdropBlur,
                          ),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withValues(alpha: 0.12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 0.5,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              size: 30,
                              color: Colors.white.withValues(alpha: 0.92),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.32),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.88),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                height: 1.15,
                color: Colors.black.withValues(alpha: 0.88),
              ),
            ),
          ),
        ],
      ),
    );
  }
}