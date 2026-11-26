import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../models/check_in_preview_point.dart';
import '../../models/location_card.dart';
import '../../services/api_client.dart';

/// 默认地图中心（南京），用于无点位或加载前占位。
const LatLng _kDefaultPreviewCenter = LatLng(32.060255, 118.796877);

/// 地图上的“带时间标签”的自定义 Marker（支持网络图与本地文件路径）。
class CheckInMarkerWidget extends StatelessWidget {
  const CheckInMarkerWidget({
    super.key,
    required this.imageUrl,
    required this.time,
    this.isSelected = false,
  });

  final String? imageUrl;
  final DateTime time;
  final bool isSelected;

  static const _kRouteYellow = Color(0xFFFFD54F);

  Widget _avatarContent() {
    if (imageUrl == null || imageUrl!.trim().isEmpty) {
      return Container(
        color: Colors.grey[300],
        child: const Icon(Icons.image, size: 20),
      );
    }
    final u = imageUrl!.trim();
    if (u.startsWith('http://') || u.startsWith('https://')) {
      return Image.network(
        u,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Colors.grey[300],
          child: const Icon(Icons.image, size: 20),
        ),
      );
    }
    return Image.file(
      File(u),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        color: Colors.grey[300],
        child: const Icon(Icons.image, size: 20),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timeString =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? Colors.white : _kRouteYellow,
              width: 3,
            ),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: ClipOval(child: _avatarContent()),
        ),
        Positioned(
          bottom: -8,
          child: CustomPaint(
            size: const Size(12, 8),
            painter: TrianglePainter(
              color: isSelected ? Colors.white : _kRouteYellow,
            ),
          ),
        ),
        Positioned(
          right: -40,
          bottom: -15,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 4),
              ],
            ),
            child: Text(
              timeString,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class TrianglePainter extends CustomPainter {
  TrianglePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant TrianglePainter oldDelegate) =>
      color != oldDelegate.color;
}

/// 仅负责底图与路线/Marker；父级在 sheet 拖动时不应 rebuild 本组件。
class _TripPreviewMapLayer extends StatelessWidget {
  const _TripPreviewMapLayer({
    required this.mapController,
    required this.initialCenter,
    required this.initialZoom,
    required this.points,
    required this.selectedPointId,
    required this.onSelectPoint,
  });

  final MapController mapController;
  final LatLng initialCenter;
  final double initialZoom;
  final List<CheckInPreviewPoint> points;
  final String? selectedPointId;
  final void Function(CheckInPreviewPoint point, int index) onSelectPoint;

  static const _kRouteYellow = Color(0xFFFFD54F);

  @override
  Widget build(BuildContext context) {
    final showRoute = points.length >= 2;
    final polylinePoints = points.map((e) => e.coordinate).toList();

    final markers = <Marker>[];
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final thumb = p.imageUrls.isNotEmpty ? p.imageUrls.first : null;
      markers.add(
        Marker(
          width: 100,
          height: 100,
          point: p.coordinate,
          child: GestureDetector(
            onTap: () => onSelectPoint(p, i),
            child: CheckInMarkerWidget(
              imageUrl: thumb,
              time: p.time,
              isSelected: p.id == selectedPointId,
            ),
          ),
        ),
      );
    }

    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
          subdomains: const ['1', '2', '3', '4'],
          userAgentPackageName: 'com.example.mobile',
        ),
        if (showRoute)
          PolylineLayer(
            polylines: [
              Polyline(
                points: polylinePoints,
                strokeWidth: 4,
                color: _kRouteYellow,
              ),
            ],
          ),
        if (markers.isNotEmpty) MarkerLayer(markers: markers),
      ],
    );
  }
}

/// 行程卡片沉浸式地图预览（只读）。
class PreviewLocationCardPage extends StatefulWidget {
  const PreviewLocationCardPage({super.key, required this.locationCard});

  final LocationCard locationCard;

  @override
  State<PreviewLocationCardPage> createState() =>
      _PreviewLocationCardPageState();
}

enum _PointsPhase { loading, ready, error }

class _PreviewLocationCardPageState extends State<PreviewLocationCardPage> {
  static const _hideAppBarThreshold = 0.75;

  final MapController _mapController = MapController();
  late final ValueNotifier<double> _sheetExtentNotifier;

  _PointsPhase _phase = _PointsPhase.loading;
  List<CheckInPreviewPoint> _points = [];
  String? _errorMessage;
  String? _selectedPointId;
  List<GlobalKey> _itemKeys = [];

  String get _tripTitle {
    final t = widget.locationCard.title.trim();
    return t.isEmpty ? '未命名行程' : t;
  }

  LatLng get _mapCenter =>
      _points.isNotEmpty ? _points.first.coordinate : _kDefaultPreviewCenter;

  double get _mapZoom => _points.isEmpty ? 11.5 : 13.2;

  @override
  void initState() {
    super.initState();
    _sheetExtentNotifier = ValueNotifier<double>(0.4);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTripPoints());
  }

  @override
  void dispose() {
    _sheetExtentNotifier.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadTripPoints() async {
    if (!mounted) return;
    setState(() {
      _phase = _PointsPhase.loading;
      _errorMessage = null;
      _points = [];
      _itemKeys = [];
      _selectedPointId = null;
    });
    try {
      final api = context.read<ApiClient>();
      final points = await api.fetchTripCheckInPreviewPoints(widget.locationCard.id);
      if (!mounted) return;
      setState(() {
        _points = points;
        _phase = _PointsPhase.ready;
        _itemKeys = List<GlobalKey>.generate(points.length, (_) => GlobalKey());
        _selectedPointId = points.isNotEmpty ? points.first.id : null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _phase != _PointsPhase.ready) return;
        if (_points.isEmpty) {
          _mapController.move(_kDefaultPreviewCenter, 11.5);
        } else {
          _mapController.move(_points.first.coordinate, 13.2);
        }
      });
    } catch (e, st) {
      debugPrint('fetchTripCheckInPreviewPoints failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _phase = _PointsPhase.error;
        _errorMessage = e is ApiException ? e.message : '$e';
        _points = [];
        _itemKeys = [];
        _selectedPointId = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.move(_kDefaultPreviewCenter, 11.5);
      });
    }
  }

  void _selectPoint(CheckInPreviewPoint point, int index) {
    setState(() => _selectedPointId = point.id);
    _mapController.move(point.coordinate, 15.5);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (index < 0 || index >= _itemKeys.length) return;
      final ctx = _itemKeys[index].currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
          alignment: 0.12,
        );
      }
    });
  }

  Widget _buildFloatingTopBar(ThemeData theme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.28),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      foregroundColor: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _tripTitle,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 52),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatCheckInTime(DateTime t) {
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildDragHandle() {
    return Center(
      child: Container(
        width: 44,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade700,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildSheetHeader(ThemeData theme, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _tripTitle,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$count 个打卡点',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black54,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassSkeletonCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 12,
                width: 120,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                height: 16,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                height: 14,
                width: 200,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLoadingSheetSlivers() {
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverToBoxAdapter(child: _buildDragHandle()),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 22,
                width: 160,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                height: 14,
                width: 100,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            _glassSkeletonCard(),
            const SizedBox(height: 12),
            _glassSkeletonCard(),
            const SizedBox(height: 12),
            _glassSkeletonCard(),
          ]),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
    ];
  }

  Widget _buildEmptySheetBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        children: [
          Icon(
            Icons.explore_outlined,
            size: 56,
            color: Colors.black.withValues(alpha: 0.28),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无打卡记录',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '该行程还没有地点打卡，去添加一些回忆吧。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black54,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorSheetBody(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Colors.orange.shade700,
          ),
          const SizedBox(height: 12),
          Text(
            '加载失败',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? '网络异常',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loadTripPoints,
            icon: const Icon(Icons.refresh, size: 20),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineRow(
    BuildContext context,
    ThemeData theme,
    CheckInPreviewPoint point,
    int index,
    bool isLast,
  ) {
    final selected = point.id == _selectedPointId;

    return KeyedSubtree(
      key: _itemKeys[index],
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _selectPoint(point, index),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 22,
                    child: Column(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: selected
                                ? const Color(0xFF6B3DBB)
                                : Colors.grey.shade400,
                            border: Border.all(
                              color: Colors.white,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                        if (!isLast)
                          Expanded(
                            child: Container(
                              width: 2,
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              color: Colors.grey.shade300,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _formatCheckInTime(point.time),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: Colors.black45,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          point.locationName.isEmpty ? '未命名地点' : point.locationName,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black87,
                          ),
                        ),
                        if (point.note.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            point.note.trim(),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.55,
                              color: Colors.black.withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                        if (point.imageUrls.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 72,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: point.imageUrls.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(width: 8),
                              itemBuilder: (ctx, i) {
                                final url = point.imageUrls[i];
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    url,
                                    width: 72,
                                    height: 72,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      width: 72,
                                      height: 72,
                                      color: Colors.grey.shade200,
                                      alignment: Alignment.center,
                                      child: const Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildReadySheetSlivers(ThemeData theme) {
    if (_points.isEmpty) {
      return [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _buildDragHandle()),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(child: _buildSheetHeader(theme, 0)),
        SliverToBoxAdapter(child: _buildEmptySheetBody(theme)),
      ];
    }
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverToBoxAdapter(child: _buildDragHandle()),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverToBoxAdapter(child: _buildSheetHeader(theme, _points.length)),
      const SliverToBoxAdapter(child: SizedBox(height: 4)),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final point = _points[index];
            final isLast = index == _points.length - 1;
            return _buildTimelineRow(
              context,
              theme,
              point,
              index,
              isLast,
            );
          },
          childCount: _points.length,
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 28)),
    ];
  }

  List<Widget> _buildSheetSliversForPhase(ThemeData theme) {
    switch (_phase) {
      case _PointsPhase.loading:
        return _buildLoadingSheetSlivers();
      case _PointsPhase.error:
        return [
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildDragHandle()),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(child: _buildSheetHeader(theme, 0)),
          SliverToBoxAdapter(child: _buildErrorSheetBody(theme)),
        ];
      case _PointsPhase.ready:
        return _buildReadySheetSlivers(theme);
    }
  }

  /// Sheet 与通知监听隔离在此子树内，拖动时通过 [ValueNotifier] 更新顶栏，不触发父级 [setState]。
  Widget _buildBottomSheetShell(ThemeData theme) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: (notification) {
          final next = notification.extent;
          if ((_sheetExtentNotifier.value - next).abs() > 0.001) {
            _sheetExtentNotifier.value = next;
          }
          return false;
        },
        child: DraggableScrollableSheet(
          initialChildSize: 0.4,
          minChildSize: 0.1,
          maxChildSize: 0.88,
          expand: false,
          builder: (context, scrollController) {
            return ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                child: Container(
                  color: Colors.white.withValues(alpha: 0.75),
                  child: CustomScrollView(
                    controller: scrollController,
                    primary: false,
                    slivers: _buildSheetSliversForPhase(theme),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;

    final mapPoints =
        _phase == _PointsPhase.ready && _points.isNotEmpty ? _points : <CheckInPreviewPoint>[];

    return Scaffold(
      backgroundColor: Colors.grey[50],
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _TripPreviewMapLayer(
                  mapController: _mapController,
                  initialCenter: _mapCenter,
                  initialZoom: _mapZoom,
                  points: mapPoints,
                  selectedPointId: _selectedPointId,
                  onSelectPoint: _selectPoint,
                ),
                if (_phase == _PointsPhase.loading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.45),
                      child: const Center(
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutQuad,
            left: 0,
            right: 0,
            bottom: bottomInset,
            height: screenHeight,
            child: _buildBottomSheetShell(theme),
          ),
          ValueListenableBuilder<double>(
            valueListenable: _sheetExtentNotifier,
            builder: (context, extent, _) {
              return AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                top: extent >= _hideAppBarThreshold ? -100 : 0,
                left: 0,
                right: 0,
                child: _buildFloatingTopBar(theme),
              );
            },
          ),
        ],
      ),
    );
  }
}
