import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import 'library_sort_mode.dart';

/// Dark purple used for Time tab pill and scrubber.
const Color _kTimeTabPurple = Color(0xFF5E4B8A);

class AllPhotosView extends StatefulWidget {
  const AllPhotosView({
    super.key,
    required this.refreshTick,
    this.onSelectionModeChanged,
    required this.sortMode,
  });

  final int refreshTick;

  /// 当进入 / 退出多选模式时通知父组件（例如隐藏 / 显示 FAB）。
  final ValueChanged<bool>? onSelectionModeChanged;

  /// 当前整理/排序模式。
  final LibrarySortMode sortMode;

  @override
  State<AllPhotosView> createState() => _AllPhotosViewState();
}

class _AllPhotosViewState extends State<AllPhotosView> {
  Future<List<dynamic>>? _future;

  // 选择模式：是否处于多选状态 & 当前选中的照片 id 集合
  bool _selectionMode = false;
  final Set<int> _selectedIds = <int>{};

  /// 当前按人物过滤所选中的人物名（null 表示不过滤）。
  String? _personFilter;

  /// 时间轴视图的滚动控制器，用于与右侧 scrubber 同步。
  final ScrollController _timeScrollController = ScrollController();
  int _timeGridCrossAxisCount = 4;
  int _timeScaleStartCount = 4;

  bool get _hasSelection => _selectedIds.isNotEmpty;

  int? _photoId(Map<String, dynamic> item) {
    final raw = item['id'];
    if (raw is int) return raw > 0 ? raw : null;
    if (raw is num) {
      final v = raw.toInt();
      return v > 0 ? v : null;
    }
    final v = int.tryParse('${raw ?? ''}');
    if (v == null || v <= 0) return null;
    return v;
  }

  String? _photoUrl(ApiClient api, Map<String, dynamic> item) {
    final raw = item['url'];
    if (raw is String && raw.trim().isNotEmpty) {
      final u = raw.trim();
      if (u.startsWith('http://') || u.startsWith('https://')) {
        return u;
      }
      return '${api.base}${u.startsWith('/') ? '' : '/'}$u';
    }
    return null;
  }

  List<Map<String, dynamic>> _normalizePhotoItems(
    ApiClient api,
    List<dynamic> photos,
  ) {
    final out = <Map<String, dynamic>>[];
    for (final raw in photos) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = _photoId(item);
      final url = _photoUrl(api, item);
      if (id == null || url == null || url.isEmpty) continue;
      out.add({
        ...item,
        'id': id,
        'url': url,
      });
    }
    return out;
  }

  @override
  void dispose() {
    _timeScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final api = context.read<ApiClient>();
    // 使用后端新的 /api/photos-advanced 接口，并根据模式传入 sort / person 参数。
    var path = '/api/photos-advanced?sort=${widget.sortMode.apiSortParam}';

    final person = _personFilter?.trim();
    if (person != null && person.isNotEmpty) {
      final encoded = Uri.encodeComponent(person);
      path = '$path&person=$encoded';
    }

    setState(() {
      _future = api.getJsonList(path);
    });
  }

  @override
  void didUpdateWidget(covariant AllPhotosView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshTick != widget.refreshTick ||
        oldWidget.sortMode != widget.sortMode) {
      _reload();
    }
  }

  void _notifySelectionModeChanged() {
    final inSelection = _selectionMode && _selectedIds.isNotEmpty;
    widget.onSelectionModeChanged?.call(inSelection);
  }

  void _enterSelectionMode(int id) {
    setState(() {
      _selectionMode = true;
      _selectedIds
        ..clear()
        ..add(id);
    });
    _notifySelectionModeChanged();
  }

  void _toggleSelection(int id) {
    if (!_selectionMode) return;
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectedIds.add(id);
      }
    });
    _notifySelectionModeChanged();
  }

  void _clearSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    _notifySelectionModeChanged();
  }

  void _togglePersonFilter(String personName) {
    setState(() {
      // 再次点击同一人物则取消过滤。
      if (_personFilter == personName) {
        _personFilter = null;
      } else {
        _personFilter = personName;
      }

      // 切换人物过滤时退出多选，避免状态混乱。
      _selectionMode = false;
      _selectedIds.clear();
    });

    _notifySelectionModeChanged();
    _reload();
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除照片'),
            content: Text('确定要删除选中的 ${_selectedIds.length} 张照片吗？此操作不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed || !mounted) return;

    final api = context.read<ApiClient>();

    // 简单串行删除，数量一般不会太大；后续可按需优化为并行。
    for (final id in _selectedIds.toList()) {
      try {
        await api.delete('/api/photos/$id');
      } catch (_) {
        // 单张删除失败不阻断整个批次，如有需要可在此处弹出提示。
      }
    }

    _clearSelection(); // 内部会触发 _notifySelectionModeChanged
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_future == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final api = context.read<ApiClient>();

    return FutureBuilder<List<dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '加载照片失败：${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        final photos = snapshot.data ?? const [];
        final normalizedPhotos = _normalizePhotoItems(api, photos);

        if (photos.isEmpty) {
          return const Center(
            child: Text('还没有照片，请点击右下角 + 添加。'),
          );
        }

        if (normalizedPhotos.isEmpty) {
          return const Center(
            child: Text('暂无可展示图片'),
          );
        }

        // 仅在“人物”模式下，根据返回的照片列表收集所有人物名称，用于顶部头像滚动条。
        List<String> personNamesForRow = const [];
        if (widget.sortMode == LibrarySortMode.people) {
          final namesSet = <String>{};
          for (final raw in normalizedPhotos) {
            final item = raw as Map<String, dynamic>;
            final List<dynamic> rawNames =
                (item['person_names'] as List<dynamic>? ?? []);
            for (final n in rawNames) {
              final name = n.toString();
              if (name.isNotEmpty) {
                namesSet.add(name);
              }
            }
          }
          personNamesForRow = namesSet.toList()..sort();
        }

        // 地点模式：按 MongoDB location 字段分组，采用与时间模式一致的排布。
        if (widget.sortMode == LibrarySortMode.location) {
          return _buildLocationGroupedView(api, normalizedPhotos);
        }

        // 时间模式：高保真时间轴布局（左侧时间线 + 右侧内容 + 右侧 scrubber）。
        if (widget.sortMode == LibrarySortMode.time) {
          return _buildTimeTimelineView(api, normalizedPhotos);
        }

        // 人物模式：顶部人物头像条 + 下方照片网格。
        return Column(
          children: [
            if (personNamesForRow.isNotEmpty)
              _PersonAvatarRow(
                personNames: personNamesForRow,
                currentFilter: _personFilter,
                onPersonTapped: _togglePersonFilter,
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _buildPhotoGrid(api, normalizedPhotos),
            ),
          ],
        );
      },
    );
  }

  /// 时间模式：时间轴 + 月/日标题 + 照片网格 + 玻璃卡片。
  Widget _buildTimeTimelineView(ApiClient api, List<Map<String, dynamic>> photos) {
    final sections = _buildTimeSections(api, photos);

    return GestureDetector(
      onScaleStart: (_) {
        _timeScaleStartCount = _timeGridCrossAxisCount;
      },
      onScaleUpdate: (details) {
        if (details.pointerCount < 2) return;
        final nextCount = (_timeScaleStartCount / details.scale).round().clamp(2, 5);
        if (nextCount != _timeGridCrossAxisCount) {
          setState(() {
            _timeGridCrossAxisCount = nextCount;
          });
        }
      },
      child: CustomScrollView(
        controller: _timeScrollController,
        slivers: _buildTimelineSlivers(api, sections, photos),
      ),
    );
  }

  Widget _buildLocationGroupedView(
    ApiClient api,
    List<Map<String, dynamic>> photos,
  ) {
    final sections = _buildLocationSections(photos);
    return Stack(
      children: [
        Positioned.fill(
          child: FlutterMap(
            options: MapOptions(
              initialCenter: const LatLng(32.0603, 118.7969),
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
                subdomains: const ['1', '2', '3', '4'],
                userAgentPackageName: 'com.example.mobile',
              ),
            ],
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(36)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(36)),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.8),
                        width: 1,
                      ),
                    ),
                  ),
                  child: GestureDetector(
                    onScaleStart: (_) {
                      _timeScaleStartCount = _timeGridCrossAxisCount;
                    },
                    onScaleUpdate: (details) {
                      if (details.pointerCount < 2) return;
                      final nextCount =
                          (_timeScaleStartCount / details.scale).round().clamp(
                                2,
                                5,
                              );
                      if (nextCount != _timeGridCrossAxisCount) {
                        setState(() {
                          _timeGridCrossAxisCount = nextCount;
                        });
                      }
                    },
                    child: CustomScrollView(
                      controller: scrollController,
                      slivers: _buildLocationSlivers(api, sections),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  /// 将照片按 taken_at(回退 created_at) 的 月 -> 日 分组，用于时间轴展示。
  List<_MonthSection> _buildTimeSections(ApiClient api, List<Map<String, dynamic>> photos) {
    final map = <String, Map<String, List<Map<String, dynamic>>>>{};
    int fallbackDay = 0;
    for (final p in photos) {
      final item = p;
      String monthKey;
      String dayKey;
      // /api/photos-advanced 的主时间字段是 taken_at；created_at 仅做回退。
      final dateStr = item['taken_at'] ?? item['created_at'];
      final dt = dateStr != null ? DateTime.tryParse(dateStr.toString()) : null;
      if (dt != null) {
        monthKey = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
        dayKey = '${dt.day.toString().padLeft(2, '0')}';
      } else {
        monthKey = 'unknown';
        fallbackDay++;
        dayKey = 'f$fallbackDay';
      }
      map.putIfAbsent(monthKey, () => {});
      map[monthKey]!.putIfAbsent(dayKey, () => []);
      map[monthKey]![dayKey]!.add(item);
    }
    final monthOrder = map.keys.toList()..sort((a, b) => a.compareTo(b));
    return monthOrder.map((monthKey) {
      final dayMap = map[monthKey]!;
      final dayOrder = dayMap.keys.toList()..sort((a, b) => a.compareTo(b));
      final days = dayOrder.map((dayKey) {
        final dayPhotos = dayMap[dayKey]!;
        final first = dayPhotos.first;
        final dateStr = first['taken_at'] ?? first['created_at'];
        final dt = dateStr != null
            ? DateTime.tryParse(dateStr.toString())
            : null;
        String dayLabel;
        if (dt != null) {
          const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
          final w = dt.weekday - 1;
          dayLabel = '${dt.month}月${dt.day}日 - ${weekdays[w]}';
        } else {
          dayLabel = '某日';
        }
        return _DaySection(dayLabel: dayLabel, photos: dayPhotos);
      }).toList();
      final yearMonth = monthKey == 'unknown'
          ? '未知日期'
          : monthKey.replaceFirst('-', '年') + '月';
      return _MonthSection(
        monthLabel: yearMonth,
        locationLabel: '', // 可后续从 API 获取地点
        days: days,
      );
    }).toList();
  }

  List<_LocationSection> _buildLocationSections(List<Map<String, dynamic>> photos) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in photos) {
      final raw = (item['location'] ?? '').toString().trim();
      final key = raw.isEmpty ? '未知地点' : raw;
      grouped.putIfAbsent(key, () => []).add(item);
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '未知地点') return 1;
        if (b == '未知地点') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return keys
        .map((k) => _LocationSection(locationLabel: k, photos: grouped[k]!))
        .toList();
  }

  List<Widget> _buildTimelineSlivers(
    ApiClient api,
    List<_MonthSection> sections,
    List<dynamic> photos,
  ) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];
    for (final section in sections) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(left: 40, right: 16, bottom: 8),
            child: Text(
              section.locationLabel.isEmpty
                  ? section.monthLabel
                  : '${section.monthLabel} - ${section.locationLabel}',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: _kTimeTabPurple,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < section.days.length; i++) {
        final day = section.days[i];
        final isFirst = i == 0;
        final isLast = i == section.days.length - 1;
        slivers.add(
          SliverToBoxAdapter(
            child: _TimelineDayRow(
              dayLabel: day.dayLabel,
              photos: day.photos,
              api: api,
              gridCrossAxisCount: _timeGridCrossAxisCount,
              isFirst: isFirst,
              isLast: isLast,
              selectedIds: _selectedIds,
              selectionMode: _selectionMode,
              onEnterSelection: _enterSelectionMode,
              onToggleSelection: _toggleSelection,
            ),
          ),
        );
      }
    }
    slivers.add(
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(left: 24, right: 16, bottom: 24),
          child: _HighlightCardsSection(api: api, photos: photos),
        ),
      ),
    );
    if (_hasSelection) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _SelectionBar(
              selectedCount: _selectedIds.length,
              onClear: _clearSelection,
              onDelete: _deleteSelected,
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  List<Widget> _buildLocationSlivers(
    ApiClient api,
    List<_LocationSection> sections,
  ) {
    final slivers = <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 16)),
    ];

    for (final section in sections) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(left: 40, right: 16, bottom: 8),
            child: Text(
              section.locationLabel,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: _kTimeTabPurple,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          child: _TimelineDayRow(
            dayLabel: section.locationLabel,
            photos: section.photos,
            api: api,
            gridCrossAxisCount: _timeGridCrossAxisCount,
            isFirst: true,
            isLast: true,
            selectedIds: _selectedIds,
            selectionMode: _selectionMode,
            onEnterSelection: _enterSelectionMode,
            onToggleSelection: _toggleSelection,
          ),
        ),
      );
    }

    if (_hasSelection) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _SelectionBar(
              selectedCount: _selectedIds.length,
              onClear: _clearSelection,
              onDelete: _deleteSelected,
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  /// 通用的照片网格 + 选择操作条布局（时间 / 人物模式使用）。
  Widget _buildPhotoGrid(
    ApiClient api,
    List<dynamic> photos,
  ) {
    return Stack(
      children: [
        GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 4,
            mainAxisSpacing: 4,
          ),
          itemCount: photos.length,
          itemBuilder: (context, index) {
            final item = photos[index] as Map<String, dynamic>;
            final id = _photoId(item);
            final url = _photoUrl(api, item);
            if (id == null || url == null) {
              return const SizedBox.shrink();
            }

            final List<String> personNames =
                (item['person_names'] as List<dynamic>? ?? [])
                    .map((e) => e.toString())
                    .toList();

            final bool selected = _selectedIds.contains(id);

            return GestureDetector(
              onLongPress: () {
                _enterSelectionMode(id);
              },
              onTap: () {
                if (_selectionMode) {
                  _toggleSelection(id);
                } else {
                  // 预览功能可以后续在这里补充。
                }
              },
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        url,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
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
                  if (personNames.isNotEmpty)
                    Positioned(
                      top: 4,
                      left: 4,
                      right: 4,
                      child: _PersonChipRow(
                        personNames: personNames,
                        currentFilter: _personFilter,
                        onPersonTapped: _togglePersonFilter,
                      ),
                    ),
                  if (_selectionMode)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: selected
                              ? Colors.lightBlueAccent
                              : Colors.white70,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        if (_hasSelection)
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: _SelectionBar(
              selectedCount: _selectedIds.length,
              onClear: _clearSelection,
              onDelete: _deleteSelected,
            ),
          ),
      ],
    );
  }
}

/// 时间轴月份分组。
class _MonthSection {
  const _MonthSection({
    required this.monthLabel,
    required this.locationLabel,
    required this.days,
  });
  final String monthLabel;
  final String locationLabel;
  final List<_DaySection> days;
}

/// 时间轴单日分组。
class _DaySection {
  const _DaySection({required this.dayLabel, required this.photos});
  final String dayLabel;
  final List<Map<String, dynamic>> photos;
}

/// 地点模式分组。
class _LocationSection {
  const _LocationSection({required this.locationLabel, required this.photos});
  final String locationLabel;
  final List<Map<String, dynamic>> photos;
}

/// 时间轴单行：左侧竖线+圆点，右侧日标题+照片网格。
class _TimelineDayRow extends StatelessWidget {
  const _TimelineDayRow({
    required this.dayLabel,
    required this.photos,
    required this.api,
    required this.gridCrossAxisCount,
    required this.isFirst,
    required this.isLast,
    required this.selectedIds,
    required this.selectionMode,
    required this.onEnterSelection,
    required this.onToggleSelection,
  });

  final String dayLabel;
  final List<Map<String, dynamic>> photos;
  final ApiClient api;
  final int gridCrossAxisCount;
  final bool isFirst;
  final bool isLast;
  final Set<int> selectedIds;
  final bool selectionMode;
  final ValueChanged<int> onEnterSelection;
  final ValueChanged<int> onToggleSelection;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 11,
          top: isFirst ? 14 : 0,
          bottom: 0,
          child: Container(width: 2, color: Colors.grey.shade400),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF5E4B8A),
                      border: Border.all(color: Colors.white, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF5E4B8A).withValues(alpha: 0.4),
                          blurRadius: 4,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LiquidGlassContainer(
                      borderRadius: 8,
                      blurSigma: 10,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      child: Text(
                        dayLabel,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF5E4B8A).withValues(alpha: 0.8),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: gridCrossAxisCount,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 1,
                      ),
                      itemCount: photos.length,
                      itemBuilder: (context, index) {
                        final item = photos[index];
                        final id = item['id'] as int?;
                        final url = item['url'] as String?;
                        if (id == null || id <= 0 || url == null || url.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        final selected = selectedIds.contains(id);
                        return GestureDetector(
                          onLongPress: () => onEnterSelection(id),
                          onTap: () {
                            if (selectionMode) {
                              onToggleSelection(id);
                            }
                          },
                          child: _TimePhotoTile(
                            url: url,
                            selected: selected,
                            selectionMode: selectionMode,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 时间轴照片缩略图：圆角 12 + 底部渐变与图标。
class _TimePhotoTile extends StatelessWidget {
  const _TimePhotoTile({
    required this.url,
    required this.selected,
    required this.selectionMode,
  });

  final String url;
  final bool selected;
  final bool selectionMode;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: Colors.grey.shade300,
              child: const Icon(Icons.broken_image, color: Colors.white70),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 32,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
          ),
        ),
        if (selectionMode)
          Positioned(
            top: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? Colors.lightBlueAccent : Colors.white70,
                size: 18,
              ),
            ),
          ),
      ],
    );
  }
}

/// 底部「Highlight Cards」区域：玻璃质感 AI 时序 + July Stories。
class _HighlightCardsSection extends StatelessWidget {
  const _HighlightCardsSection({required this.api, required this.photos});

  final ApiClient api;
  final List<dynamic> photos;

  static Widget _glassCard({
    required Widget child,
    EdgeInsets? padding,
  }) {
    return LiquidGlassContainer(
      borderRadius: 20,
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sampleUrls = photos.take(6).map((p) {
      final item = p as Map<String, dynamic>;
      final rawUrl = item['url'];
      if (rawUrl is String && rawUrl.trim().isNotEmpty) {
        final u = rawUrl.trim();
        if (u.startsWith('http://') || u.startsWith('https://')) {
          return u;
        }
        return '${api.base}${u.startsWith('/') ? '' : '/'}$u';
      }
      return '';
    }).where((u) => u.isNotEmpty).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 12),
          child: Text(
            'Highlight Cards',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: _glassCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'AI 时序: 关键事件',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _kTimeTabPurple,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 72,
                      child: Row(
                        children: [
                          for (var i = 0; i < sampleUrls.length && i < 4; i++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(right: i < 3 ? 6 : 0),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    sampleUrls[i],
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: Colors.grey.shade300,
                                      child: const Icon(Icons.image),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _glassCard(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'July Stories',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: _kTimeTabPurple,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 80,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (sampleUrls.isNotEmpty) ...[
                            Positioned(left: 0, right: 8, top: 4, bottom: 4,
                              child: _StackedCardImage(url: sampleUrls[0])),
                            Positioned(left: 4, right: 4, top: 2, bottom: 6,
                              child: _StackedCardImage(url: sampleUrls.length > 1 ? sampleUrls[1] : sampleUrls[0])),
                            Positioned(left: 8, right: 0, top: 0, bottom: 8,
                              child: _StackedCardImage(url: sampleUrls.length > 2 ? sampleUrls[2] : sampleUrls[0])),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StackedCardImage extends StatelessWidget {
  const _StackedCardImage({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: Colors.grey.shade300,
            child: const Icon(Icons.image),
          ),
        ),
      ),
    );
  }
}

/// 极致柔和的液态玻璃容器
class LiquidGlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blurSigma;

  const LiquidGlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 24.0,
    this.padding,
    this.blurSigma = 20.0,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.6),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 15,
                spreadRadius: -5,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.onClear,
    required this.onDelete,
  });

  final int selectedCount;
  final VoidCallback onClear;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: LiquidGlassContainer(
        borderRadius: 30,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$selectedCount',
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              '已选择',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                foregroundColor: Colors.black54,
              ),
              child: const Text('取消'),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: theme.colorScheme.error,
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.error.withValues(alpha: 0.1),
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _PersonChipRow extends StatelessWidget {
  const _PersonChipRow({
    required this.personNames,
    required this.currentFilter,
    required this.onPersonTapped,
  });

  final List<String> personNames;
  final String? currentFilter;
  final ValueChanged<String> onPersonTapped;

  @override
  Widget build(BuildContext context) {
    if (personNames.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final name in personNames)
            _PersonChip(
              name: name,
              selected: currentFilter == name,
              onTap: () => onPersonTapped(name),
            ),
        ],
      ),
    );
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayLetter =
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?';

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.9)
                : Colors.black45,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.onPrimary.withValues(alpha: 0.9)
                  : Colors.white38,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 9,
                backgroundColor: Colors.white24,
                child: Text(
                  displayLetter,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 60),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected
                        ? theme.colorScheme.onPrimary
                        : Colors.white,
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

/// 人物模式下，顶部横向滚动的大号圆形头像列表。
class _PersonAvatarRow extends StatelessWidget {
  const _PersonAvatarRow({
    required this.personNames,
    required this.currentFilter,
    required this.onPersonTapped,
  });

  final List<String> personNames;
  final String? currentFilter;
  final ValueChanged<String> onPersonTapped;

  @override
  Widget build(BuildContext context) {
    if (personNames.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: const Color(0x99FFFFFF),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 15,
                  spreadRadius: -2,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 64,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    _AddPersonAvatarItem(
                      onTap: () => _showAddPersonDialog(context),
                    ),
                    const SizedBox(width: 12),
                    for (final name in personNames)
                      _PersonAvatarItem(
                        letter: name.isNotEmpty
                            ? name.characters.first.toUpperCase()
                            : '?',
                        selected: currentFilter == name,
                        onTap: () => onPersonTapped(name),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showAddPersonDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) {
        final textController = TextEditingController();
        return AlertDialog(
          title: const Text('添加人物'),
          content: TextField(
            controller: textController,
            decoration: const InputDecoration(
              labelText: '人物名称',
              hintText: '例如：Leamon',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }
}

class _PersonAvatarItem extends StatelessWidget {
  const _PersonAvatarItem({
    required this.letter,
    required this.selected,
    required this.onTap,
  });

  final String letter;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double size = 64;
    final theme = Theme.of(context);
    final Color glassyBase = Colors.white.withValues(alpha: 0.15);
    final Color glassyActive =
        theme.colorScheme.primary.withValues(alpha: 0.35);

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: GestureDetector(
        onTap: onTap,
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? glassyActive : glassyBase,
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary.withValues(alpha: 0.6)
                      : const Color(0x7FFFFFFF),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: selected
                        ? theme.colorScheme.primary.withValues(alpha: 0.18)
                        : Colors.black.withValues(alpha: 0.05),
                    blurRadius: selected ? 22 : 15,
                    spreadRadius: selected ? 1 : 0,
                    offset:
                        selected ? const Offset(0, 0) : const Offset(0, 4),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  letter,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? Colors.white
                        : theme.colorScheme.primary.withValues(alpha: 0.9),
                    letterSpacing: 0.5,
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

class _AddPersonAvatarItem extends StatelessWidget {
  const _AddPersonAvatarItem({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const double size = 64;
    final theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    const Color baseBackground = Colors.white;

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size / 2),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: baseBackground,
              border: Border.all(
                color: const Color(0x99FFFFFF),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 18,
                  spreadRadius: 1,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                Icons.add,
                size: 26,
                color: accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

