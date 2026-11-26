import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:coordtransform/coordtransform.dart';
import 'package:latlong2/latlong.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import 'photo_enhanced_editor_dialog.dart';

/// 行程打卡草稿：每个点位拥有独立状态（地点名/随笔/多图）。
class CheckInDraft {
  final String id;
  LatLng coordinate;
  DateTime time;
  String locationName;
  String note;
  List<File> selectedImageFiles;

  CheckInDraft({
    required this.id,
    required this.coordinate,
    required this.time,
    this.locationName = '',
    this.note = '',
    List<File>? selectedImageFiles,
  }) : selectedImageFiles = selectedImageFiles ?? <File>[];
}

/// 地图上的“带时间标签”的自定义 Marker。
class CheckInMarkerWidget extends StatelessWidget {
  final String? imageUrl;
  final DateTime time;
  final bool isSelected;

  const CheckInMarkerWidget({
    super.key,
    required this.imageUrl,
    required this.time,
    this.isSelected = false,
  });

  @override
  Widget build(BuildContext context) {
    // 格式化时间，例如 "14:30"
    final timeString =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    const kRouteYellow = Color(0xFFFFD54F);

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
              color: isSelected ? Colors.white : kRouteYellow,
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
          child: ClipOval(
            child: (imageUrl == null || imageUrl!.trim().isEmpty)
                ? Container(
                    color: Colors.grey[300],
                    child: const Icon(Icons.image, size: 20),
                  )
                : Image.file(
                    File(imageUrl!),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.image, size: 20),
                    ),
                  ),
          ),
        ),
        Positioned(
          bottom: -8,
          child: CustomPaint(
            size: const Size(12, 8),
            painter: TrianglePainter(
              color: isSelected ? Colors.white : kRouteYellow,
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
  final Color color;
  TrianglePainter({required this.color});

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

class AddLocationCardPage extends StatefulWidget {
  const AddLocationCardPage({super.key});

  @override
  State<AddLocationCardPage> createState() => _AddLocationCardPageState();
}

class _AddLocationCardPageState extends State<AddLocationCardPage> {
  static const kRouteYellow = Color(0xFFFFD54F);
  static const Color kAiPurple = Color(0xFF6B3DBB);

  final MapController _mapController = MapController();
  final TextEditingController _tripTitleController =
      TextEditingController(text: '我的新旅程');

  final ImagePicker _picker = ImagePicker();

  // AI 输入状态（内嵌在 BottomSheet 顶部）。
  bool _showAIInput = false;
  bool _isAISending = false;
  final TextEditingController _aiPromptController = TextEditingController();
  final FocusNode _aiFocusNode = FocusNode();

  bool _isSaving = false;
  bool _isLocatingByGps = false;
  /// 键盘「搜索」提交时仍走 POI，用于选中第一个结果。
  bool _isSearchingPoi = false;
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;

  // 底部面板的当前展开比例（会由 DraggableScrollableSheet 通知更新）
  double _sheetExtent = 0.4;
  // 触发顶部导航栏隐藏的阈值（当面板高度超过屏幕 75% 时隐藏）
  final double _hideAppBarThreshold = 0.75;

  /// 点位草稿列表与当前选中点。
  final List<CheckInDraft> _checkInPoints = <CheckInDraft>[];
  CheckInDraft? _currentPoint;

  final TextEditingController _locationController =
      TextEditingController();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocusNode = FocusNode();

  /// 记录每个 CheckInDraft 对应的当前大图预览路径。
  final Map<String, String> _currentPreviewImageMap = <String, String>{};

  /// 缓存每个点位图片上传后的后端 photo_id（顺序与 selectedImageFiles 对齐）
  final Map<String, List<int>> _pointPhotoIdsMap =
      <String, List<int>>{};

  /// 防止同一个点位重复触发上传
  final Set<String> _pointUploadingIds = <String>{};

  @override
  void initState() {
    super.initState();
    final initialPoint = CheckInDraft(
      id: _newPointId(),
      coordinate: const LatLng(32.0603, 118.7969),
      time: DateTime.now(),
      locationName: '',
      note: '',
    );
    _checkInPoints.add(initialPoint);
    _switchCurrentPoint(initialPoint);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showTitleEditDialog();
    });
  }

  Future<void> _showTitleEditDialog() async {
    if (!mounted) return;
    final snapshot = _tripTitleController.text;
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.12),
      builder: (ctx) {
        return Dialog(
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.only(top: 140, left: 24, right: 24),
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.42),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '编辑标题',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _tripTitleController,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: '输入旅程标题',
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.72),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.black.withValues(alpha: 0.08),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.black.withValues(alpha: 0.08),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: kAiPurple,
                              width: 1.5,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              _tripTitleController.text = snapshot;
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(
                              '确认',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: kAiPurple,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tripTitleController.dispose();
    _locationController.dispose();
    _noteController.dispose();
    _noteFocusNode.dispose();
    _aiPromptController.dispose();
    _aiFocusNode.dispose();
    super.dispose();
  }

  String _newPointId() => DateTime.now().microsecondsSinceEpoch.toString();

  void _debugPrintCheckInPoints() {
    final data = _checkInPoints
        .map(
          (p) => <String, dynamic>{
            'id': p.id,
            'coordinate': {
              'latitude': p.coordinate.latitude,
              'longitude': p.coordinate.longitude,
            },
            'time': p.time.toIso8601String(),
            'location_name': p.locationName,
            'note': p.note,
            'selected_image_paths': p.selectedImageFiles.map((f) => f.path).toList(),
          },
        )
        .toList();
    debugPrint('CHECK_IN_POINTS_JSON: $data');
  }

  /// 空点位：无图、无随笔、地名为空（过滤后不参与保存）。
  bool _isVacantCheckInPoint(CheckInDraft p) {
    final noImages = p.selectedImageFiles.isEmpty;
    final noNote = p.note.trim().isEmpty;
    final noName = p.locationName.trim().isEmpty;
    return noImages && noNote && noName;
  }

  String _normalizePhotoBasename(String path) {
    return path.split(RegExp(r'[/\\]')).last.trim().toLowerCase();
  }

  /// 将 [ApiClient.uploadPhotosBatch] 返回的 `added` / `duplicates` 按本地文件顺序解析为 photo id。
  List<int> _photoIdsFromBatchResult(
    Map<String, dynamic> result,
    List<File> filesInOrder,
  ) {
    final added = (result['added'] as List<dynamic>? ?? const []);
    final dups = (result['duplicates'] as List<dynamic>? ?? const []);
    final items = <Map<String, dynamic>>[];
    for (final x in [...added, ...dups]) {
      if (x is Map<String, dynamic>) {
        items.add(x);
      } else if (x is Map) {
        items.add(Map<String, dynamic>.from(x));
      }
    }
    final used = <int>{};
    final ids = <int>[];
    for (final f in filesInOrder) {
      final want = _normalizePhotoBasename(f.path);
      var pickedIdx = -1;
      int? pickedId;
      for (var i = 0; i < items.length; i++) {
        if (used.contains(i)) continue;
        final m = items[i];
        final orig = m['original_filename']?.toString() ?? '';
        if (_normalizePhotoBasename(orig) != want) continue;
        final rawId = m['id'];
        if (rawId == null) continue;
        final vid = rawId is int ? rawId : int.tryParse(rawId.toString());
        if (vid == null || vid <= 0) continue;
        pickedIdx = i;
        pickedId = vid;
        break;
      }
      if (pickedIdx >= 0 && pickedId != null) {
        used.add(pickedIdx);
        ids.add(pickedId);
      }
    }
    return ids;
  }

  Future<List<int>> _ensurePointPhotoIdsUploaded(CheckInDraft p) async {
    if (p.selectedImageFiles.isEmpty) return const [];

    final cached = _pointPhotoIdsMap[p.id];
    if (cached != null && cached.length == p.selectedImageFiles.length) {
      return cached;
    }

    // 防止同一时刻重复上传
    if (_pointUploadingIds.contains(p.id)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片正在上传中，请稍后再试')),
        );
      }
      return const [];
    }

    _pointUploadingIds.add(p.id);
    if (!mounted) return const [];

    // 上传期间给一个阻塞式 loading，避免用户误触其他关键按钮。
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final api = context.read<ApiClient>();
      final files = p.selectedImageFiles;
      final batch = await api.uploadPhotosBatch(files);
      final photoIds = _photoIdsFromBatchResult(batch, files);

      if (!mounted) return const [];
      setState(() {
        _pointPhotoIdsMap[p.id] = photoIds;
      });

      // 按点位“当前地址/时间”设置 Mongo 增强字段（people 默认仍为空）。
      final locationName = p.locationName.trim().isNotEmpty
          ? p.locationName.trim()
          : '未命名地点';

      await Future.wait(
        photoIds.map(
          (id) => api.patchPhotoEnhanced(
            id,
            takenAt: p.time,
            location: locationName,
          ),
        ),
      );

      return photoIds;
    } finally {
      // 关闭 loading dialog
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      _pointUploadingIds.remove(p.id);
    }
  }

  Future<void> _openPhotoEnhancedDialogForIndex(
    CheckInDraft p,
    int index,
  ) async {
    if (index < 0 || index >= p.selectedImageFiles.length) return;
    final photoIds = await _ensurePointPhotoIdsUploaded(p);
    if (photoIds.isEmpty) return;
    if (index >= photoIds.length) return;

    final photoId = photoIds[index];
    final filePath = p.selectedImageFiles[index].path;
    final ImageProvider<Object> imageProvider =
        filePath.startsWith('http://') || filePath.startsWith('https://')
            ? NetworkImage(filePath)
            : FileImage(File(filePath));

    await showDialog<void>(
      context: context,
      builder: (_) => PhotoEnhancedEditorDialog(
        photoId: photoId,
        imageProvider: imageProvider,
      ),
    );
  }

  Future<void> _showSaveFailedDialog(Object error) async {
    if (!mounted) return;
    final platform = Theme.of(context).platform;
    final useCupertino = platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS;
    final message = error.toString();
    if (useCupertino) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          title: const Text('保存失败'),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('保存失败'),
          content: SingleChildScrollView(
            child: Text(message),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    }
  }

  /// 保存：标题校验 → 过滤空点位 → 批量上传图片 → 组装 Payload → [createTrip] → 成功则关闭页。
  Future<void> _submitTripWithValidation() async {
    final rawTitle = _tripTitleController.text.trim();
    if (rawTitle.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入路径标题')),
      );
      return;
    }

    final validPoints =
        _checkInPoints.where((p) => !_isVacantCheckInPoint(p)).toList();
    if (validPoints.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少记录一个有效的打卡点')),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isSaving = true);
    try {
      final api = context.read<ApiClient>();

      final pointPayloads = <Map<String, dynamic>>[];
      for (final p in validPoints) {
        List<int> photoIds = List<int>.from(_pointPhotoIdsMap[p.id] ?? const []);
        final files = p.selectedImageFiles;
        final needUpload = photoIds.isEmpty && files.isNotEmpty;
        if (needUpload) {
          final batch = await api.uploadPhotosBatch(files);
          photoIds = _photoIdsFromBatchResult(batch, files);
          _pointPhotoIdsMap[p.id] = photoIds;

          // 仅对“本次新增上传”的图片写入默认 location/time，避免覆盖用户手动编辑。
          if (photoIds.isNotEmpty) {
            final locationName = p.locationName.trim().isNotEmpty
                ? p.locationName.trim()
                : '未命名地点';
            await Future.wait(
              photoIds.map(
                (id) => api.patchPhotoEnhanced(
                  id,
                  takenAt: p.time,
                  location: locationName,
                ),
              ),
            );
          }
        }
        pointPayloads.add(<String, dynamic>{
          'location_name': p.locationName.trim(),
          'latitude': p.coordinate.latitude,
          'longitude': p.coordinate.longitude,
          'time': p.time.toIso8601String(),
          'note': p.note.trim(),
          'photo_ids': photoIds,
        });
      }

      final result = await api.createTrip(
        title: rawTitle,
        points: pointPayloads,
      );

      debugPrint(
        'TRIP_SAVE_RESULT:\n${const JsonEncoder.withIndent('  ').convert(result)}',
      );

      if (!mounted) return;
      setState(() => _isSaving = false);
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        const SnackBar(content: Text('保存成功')),
      );
    } catch (e, stackTrace) {
      debugPrint('保存流程异常: $e\n$stackTrace');
      if (mounted) {
        setState(() => _isSaving = false);
        await _showSaveFailedDialog(e);
      }
    }
  }

  void _switchCurrentPoint(CheckInDraft point) {
    _debounce?.cancel();
    setState(() {
      _currentPoint = point;
      _locationController.text = point.locationName;
      _noteController.text = point.note;
      _suggestions = [];
      _isSearchingPoi = false;
      _ensurePreviewPathValid(point);
    });
  }

  void _selectPoint(CheckInDraft point) {
    _switchCurrentPoint(point);
    _mapController.move(point.coordinate, 15.5);
  }

  Future<bool> _showDeleteCheckInPointDialog() async {
    final platform = Theme.of(context).platform;
    final useCupertino = platform == TargetPlatform.iOS ||
        platform == TargetPlatform.macOS;

    if (useCupertino) {
      final result = await showCupertinoDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return CupertinoAlertDialog(
            title: const Text('删除打卡点'),
            content: const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('确定要删除该打卡点吗？'),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除'),
              ),
            ],
          );
        },
      );
      return result == true;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('删除打卡点'),
          content: const Text('确定要删除该打卡点吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                '取消',
                style: TextStyle(color: Colors.grey[700]),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  /// 长按 Tab 删除点位：确认后更新列表、当前选中与地图。
  Future<void> _deleteCheckInPoint(CheckInDraft point) async {
    final confirmed = await _showDeleteCheckInPointDialog();
    if (!confirmed || !mounted) return;

    final wasCurrent = _currentPoint?.id == point.id;
    setState(() {
      _checkInPoints.remove(point);
      _currentPreviewImageMap.remove(point.id);
      if (_checkInPoints.isEmpty) {
        final fresh = CheckInDraft(
          id: _newPointId(),
          coordinate: point.coordinate,
          time: DateTime.now(),
          locationName: '',
          note: '',
        );
        _checkInPoints.add(fresh);
        _currentPoint = fresh;
        _locationController.text = fresh.locationName;
        _noteController.text = fresh.note;
      } else if (wasCurrent) {
        final last = _checkInPoints.last;
        _currentPoint = last;
        _locationController.text = last.locationName;
        _noteController.text = last.note;
      }
    });

    if (wasCurrent && mounted) {
      final target = _currentPoint!;
      _mapController.move(target.coordinate, _mapController.camera.zoom);
    }
    _debugPrintCheckInPoints();
  }

  void _ensurePreviewPathValid(CheckInDraft p) {
    if (p.selectedImageFiles.isEmpty) {
      _currentPreviewImageMap.remove(p.id);
      return;
    }
    final cur = _currentPreviewImageMap[p.id];
    if (cur == null || !p.selectedImageFiles.any((f) => f.path == cur)) {
      _currentPreviewImageMap[p.id] = p.selectedImageFiles.first.path;
    }
  }

  void _onRemovedPhoto(CheckInDraft p, String removedPath) {
    if (p.selectedImageFiles.isEmpty) {
      _currentPreviewImageMap.remove(p.id);
      _pointPhotoIdsMap.remove(p.id);
      return;
    }
    final cur = _currentPreviewImageMap[p.id];
    if (cur == null || cur == removedPath) {
      _currentPreviewImageMap[p.id] = p.selectedImageFiles.first.path;
    } else if (!p.selectedImageFiles.any((f) => f.path == cur)) {
      _currentPreviewImageMap[p.id] = p.selectedImageFiles.first.path;
    }

    // 图片列表变更后：已经上传过的 photo_id 可能不再对齐，需要重新上传/映射。
    _pointPhotoIdsMap.remove(p.id);
  }

  Future<void> _pickImages() async {
    final point = _currentPoint;
    if (point == null) return;
    try {
      final picked = await _picker.pickMultiImage(imageQuality: 92);
      if (picked.isEmpty) return;
      if (!mounted) return;
      setState(() {
        point.selectedImageFiles.addAll(picked.map((e) => File(e.path)));
        // 图片列表变更后：已经上传过的 photo_id 可能不再对齐，需要重新上传/映射。
        _pointPhotoIdsMap.remove(point.id);
        _ensurePreviewPathValid(point);
      });
      _debugPrintCheckInPoints();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('选择图片失败')),
      );
    }
  }

  /// 逆地理编码：高德 Web 服务（GCJ-02）；失败时保留原地名或使用“未命名地点”。
  Future<String> _resolveDisplayNameFromCoordinates(
    double latitude,
    double longitude,
    ApiClient api,
    String? fallbackName,
  ) async {
    final fallback = (fallbackName ?? '').trim().isNotEmpty
        ? fallbackName!.trim()
        : '未命名地点';
    try {
      final name = await api.getAmapLocationName(latitude, longitude);
      final t = name.trim();
      if (t.isEmpty ||
          t == '未知地点' ||
          t == '定位解析失败') {
        return fallback;
      }
      return t;
    } catch (_) {
      return fallback;
    }
  }

  static bool _latLngNearlyEqual(LatLng a, LatLng b) {
    const eps = 1e-7;
    return (a.latitude - b.latitude).abs() < eps &&
        (a.longitude - b.longitude).abs() < eps;
  }

  /// 地图点击选点：更新当前点位坐标，可选异步逆地理编码更新地名。
  void _onMapTapSelectPoint(TapPosition tapPosition, LatLng point) {
    final current = _currentPoint;
    if (current == null) return;
    setState(() {
      current.coordinate = point;
    });
    _mapController.move(point, _mapController.camera.zoom);
    _debugPrintCheckInPoints();

    final tapped = point;
    final api = context.read<ApiClient>();
    _resolveDisplayNameFromCoordinates(
      tapped.latitude,
      tapped.longitude,
      api,
      current.locationName,
    ).then((name) {
      if (!mounted) return;
      final cur = _currentPoint;
      if (cur == null || !_latLngNearlyEqual(cur.coordinate, tapped)) return;
      setState(() {
        cur.locationName = name;
        _locationController.text = name;
      });
      _debugPrintCheckInPoints();
    });
  }

  Future<void> _locateCurrentPointByGps() async {
    final point = _currentPoint;
    if (point == null || _isLocatingByGps) return;

    setState(() => _isLocatingByGps = true);
    try {
      final api = context.read<ApiClient>();
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('请先开启系统定位服务');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        throw Exception('定位权限被拒绝，请允许后重试');
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('定位权限已永久拒绝，请前往系统设置开启');
      }

      final locationSettings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              forceLocationManager: true,
              timeLimit: Duration(seconds: 10),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10),
            );
      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );
      // WGS84 -> GCJ02 for Amap-compatible map/render/geocode.
      final gcj02 = CoordTransform.transformWGS84toGCJ02(
        position.longitude,
        position.latitude,
      );
      final coordinate = LatLng(gcj02.lat, gcj02.lon);
      final resolvedName = await _resolveDisplayNameFromCoordinates(
        coordinate.latitude,
        coordinate.longitude,
        api,
        point.locationName,
      );

      if (!mounted) return;
      setState(() {
        point.coordinate = coordinate;
        point.locationName = resolvedName;
        _locationController.text = resolvedName;
      });
      _mapController.move(coordinate, 15.5);
      _debugPrintCheckInPoints();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('定位失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLocatingByGps = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      resizeToAvoidBottomInset: false,
      floatingActionButton: _isSaving || _showAIInput
          ? null
          : _buildAIExploreFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: Stack(
        children: [
          Positioned.fill(child: _buildMap()),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutQuad,
            left: 0,
            right: 0,
            bottom: bottomInset,
            height: screenHeight,
            child: _buildBottomSheet(),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            top: _sheetExtent >= _hideAppBarThreshold ? -100 : 0,
            left: 0,
            right: 0,
            child: _buildFloatingTopBar(theme),
          ),
          if (_isSaving) _buildFullScreenSaveOverlay(),
          if (_showAIInput) _buildAIFloatingPanel(),
        ],
      ),
    );
  }

  /// 保存流程中的全屏半透明 Loading（挡操作、防重复提交）。
  Widget _buildFullScreenSaveOverlay() {
    return Positioned.fill(
      child: AbsorbPointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
              ),
            ),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 26,
                      vertical: 20,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.32),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            color: kAiPurple,
                            strokeWidth: 2.5,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '正在打包你的旅程...',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.96),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    final initialCenter = _checkInPoints.isNotEmpty
        ? _checkInPoints.first.coordinate
        : const LatLng(32.0603, 118.7969);
    final polylinePoints = _checkInPoints.map((e) => e.coordinate).toList();

    final markers = _checkInPoints.map((p) {
      return Marker(
        width: 100,
        height: 100,
        point: p.coordinate,
        child: GestureDetector(
          onTap: () => _selectPoint(p),
          child: CheckInMarkerWidget(
            imageUrl: p.selectedImageFiles.isNotEmpty
                ? p.selectedImageFiles.first.path
                : null,
            time: p.time,
            isSelected: p.id == _currentPoint?.id,
          ),
        ),
      );
    }).toList();

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 15.5,
        onTap: _onMapTapSelectPoint,
      ),
      children: [
        TileLayer(
          urlTemplate:
              'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
          subdomains: const ['1', '2', '3', '4'],
          userAgentPackageName: 'com.example.mobile',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: polylinePoints,
              strokeWidth: 4,
              color: kRouteYellow,
            ),
          ],
        ),
        MarkerLayer(markers: markers),
      ],
    );
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.28),
                border: Border.all(
                  color: Colors.white.withOpacity(0.4),
                  width: 1.0,
                ),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.18),
                      foregroundColor: Colors.black87,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showTitleEditDialog,
                      child: ListenableBuilder(
                        listenable: _tripTitleController,
                        builder: (context, _) {
                          final raw = _tripTitleController.text;
                          final trimmed = raw.trim();
                          final isPlaceholder = trimmed.isEmpty;
                          return Text(
                            isPlaceholder ? '点击设置标题' : raw,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: isPlaceholder
                                  ? Colors.black.withValues(alpha: 0.38)
                                  : Colors.black87,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _isSaving ? null : _submitTripWithValidation,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.85, end: 1)
                                .animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: _isSaving
                          ? SizedBox(
                              key: const ValueKey('publish_loading'),
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: kAiPurple,
                              ),
                            )
                          : Text(
                              '发布',
                              key: const ValueKey('publish_label'),
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: kAiPurple,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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

  Widget _buildBottomSheet() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: (notification) {
          final nextExtent = notification.extent;
          if ((nextExtent - _sheetExtent).abs() > 0.001) {
            setState(() => _sheetExtent = nextExtent);
          }
          return false;
        },
        child: Builder(
          builder: (context) {
            return DraggableScrollableSheet(
              initialChildSize: _sheetExtent,
              minChildSize: 0.1,
              maxChildSize: 0.8,
              expand: false,
              builder: (context, scrollController) {
                return ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      color: Colors.white.withOpacity(0.75),
                      child: CustomScrollView(
                        controller: scrollController,
                        primary: false,
                        slivers: [
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 12),
                          ),
                          SliverToBoxAdapter(child: _buildDragHandle()),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 12),
                          ),
                          SliverToBoxAdapter(child: _buildLocationTabs()),
                          const SliverToBoxAdapter(child: SizedBox(height: 12)),
                          SliverToBoxAdapter(child: _buildAddImagePlaceholder()),
                          const SliverToBoxAdapter(child: SizedBox(height: 12)),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildLocationForm(),
                                  const SizedBox(height: 12),
                                  _buildNoteEditor(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildAIExploreFab() {
    return GestureDetector(
      onTap: () {
        setState(() => _showAIInput = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _aiFocusNode.requestFocus();
        });
      },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [
            BoxShadow(
              color: kAiPurple.withValues(alpha: 0.42),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFC4A5F5),
              Color(0xFF8B5CF6),
              Color(0xFF5B2CB8),
            ],
          ),
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.auto_awesome,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildAIFloatingPanel() {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 88 + bottomInset,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: Colors.white.withOpacity(0.92),
            elevation: 6,
            shadowColor: Colors.black26,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kAiPurple.withOpacity(0.12),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: kAiPurple,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _aiPromptController,
                      focusNode: _aiFocusNode,
                      maxLines: 2,
                      minLines: 1,
                      decoration: InputDecoration(
                        hintText: '告诉 AI 你想怎么探索',
                        hintStyle: TextStyle(
                          color: Colors.black.withOpacity(0.35),
                        ),
                        border: InputBorder.none,
                        isCollapsed: true,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: _isAISending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    color: kAiPurple,
                    onPressed: _isAISending
                        ? null
                        : () async {
                            final prompt = _aiPromptController.text.trim();
                            if (prompt.isEmpty) return;
                            setState(() => _isAISending = true);
                            if (!mounted) return;
                            final api = context.read<ApiClient>();
                            try {
                              final locationName = _locationController.text.trim();
                              final safeLocationName = locationName.isNotEmpty
                                  ? locationName
                                  : '未命名地点';

                              final result = await api.botChat([
                                {
                                  'role': 'user',
                                  'content':
                                      '基于地点「$safeLocationName」，给出 3 条适合散步/打卡的路线或拍照点建议。要求简洁、中文、条目化。用户输入：$prompt'
                                }
                              ]);

                              if (!mounted) return;
                              setState(() {
                                _isAISending = false;
                                _showAIInput = false;
                              });
                              _aiPromptController.clear();
                              _aiFocusNode.unfocus();

                              final preview = result.content.trim().replaceAll('\n', ' ');
                              final end = preview.length.clamp(0, 40);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content: Text(preview.substring(0, end))),
                              );
                            } catch (_) {
                              if (!mounted) return;
                              setState(() => _isAISending = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('AI 调用失败（请检查后端配置）')),
                              );
                            }
                          },
                    tooltip: '发送',
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    color: Colors.black.withOpacity(0.45),
                    onPressed: () {
                      setState(() => _showAIInput = false);
                      _aiPromptController.clear();
                      _aiFocusNode.unfocus();
                    },
                    tooltip: '关闭',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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

  Widget _buildLocationTabs() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _checkInPoints.map((point) {
                  final displayName = point.locationName.trim().isNotEmpty
                      ? point.locationName.trim()
                      : '地点';
                  final selected = point.id == _currentPoint?.id;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _selectPoint(point),
                    onLongPress: () => _deleteCheckInPoint(point),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      margin: const EdgeInsets.only(right: 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              displayName,
                              style: TextStyle(
                                fontWeight:
                                    selected ? FontWeight.w700 : FontWeight.w500,
                                color: selected
                                    ? Colors.black87
                                    : Colors.grey[400],
                              ),
                            ),
                          ),
                          Container(
                            height: 2,
                            width: 12,
                            decoration: BoxDecoration(
                              color: selected
                                  ? const Color(0xFF6B3DBB)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              final base = _currentPoint ??
                  (_checkInPoints.isNotEmpty ? _checkInPoints.last : null);
              final next = CheckInDraft(
                id: _newPointId(),
                coordinate: base?.coordinate ?? const LatLng(32.0603, 118.7969),
                time: DateTime.now(),
                locationName: '',
                note: '',
              );
              setState(() {
                _checkInPoints.add(next);
              });
              _switchCurrentPoint(next);
              _debugPrintCheckInPoints();
            },
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFF5F3FA),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Color(0xFF6B5A8E),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddImagePlaceholder() {
    final p = _currentPoint;
    if (p == null) {
      return const SizedBox.shrink();
    }
    final selectedFiles = p.selectedImageFiles;
    final hasImage = selectedFiles.isNotEmpty;
    const borderRadius = 16.0;
    final mainPath = _currentPreviewImageMap[p.id] ??
        (selectedFiles.isNotEmpty ? selectedFiles.first.path : '');
    final mainIndex = selectedFiles.indexWhere((f) => f.path == mainPath);
    final mainImageIndex = mainIndex >= 0 ? mainIndex : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Material(
          color: const Color(0xFFF5F3FA),
          child: hasImage
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(borderRadius),
                        child: InkWell(
                          onTap: () => _openPhotoEnhancedDialogForIndex(
                            p,
                            mainImageIndex,
                          ),
                          child: Image.file(
                            File(mainPath),
                            width: double.infinity,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey[300],
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image_rounded),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      child: SizedBox(
                        height: 64,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: selectedFiles.length + 1,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final isAdd = index == selectedFiles.length;
                            if (isAdd) {
                              return InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: _pickImages,
                                child: SizedBox(
                                  width: 64,
                                  height: 64,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      color: Colors.black.withOpacity(0.04),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.add_rounded,
                                        size: 26,
                                        color: Color(0xFF6B5A8E),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                            final file = selectedFiles[index];
                            return InkWell(
                              onTap: () async {
                                setState(() {
                                  _currentPreviewImageMap[p.id] = file.path;
                                });
                                await _openPhotoEnhancedDialogForIndex(
                                  p,
                                  index,
                                );
                              },
                              borderRadius: BorderRadius.circular(12),
                              child: SizedBox(
                                width: 64,
                                height: 64,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Image.file(
                                        file,
                                        fit: BoxFit.cover,
                                        width: 64,
                                        height: 64,
                                        errorBuilder: (_, __, ___) {
                                          return Container(
                                            color: Colors.grey[200],
                                            child: const Icon(
                                              Icons.broken_image_rounded,
                                              color: Colors.grey,
                                            ),
                                          );
                                        },
                                      ),
                                      Positioned(
                                        right: 4,
                                        top: 4,
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(999),
                                          child: BackdropFilter(
                                            filter: ui.ImageFilter.blur(
                                              sigmaX: 10,
                                              sigmaY: 10,
                                            ),
                                            child: Material(
                                              color: Colors.black
                                                  .withOpacity(0.22),
                                              shape: const CircleBorder(),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                onTap: () {
                                                  final removedPath = file.path;
                                                  setState(() {
                                                    p.selectedImageFiles
                                                        .removeAt(index);
                                                    _onRemovedPhoto(
                                                      p,
                                                      removedPath,
                                                    );
                                                  });
                                                  _debugPrintCheckInPoints();
                                                },
                                                child: const SizedBox(
                                                  width: 22,
                                                  height: 22,
                                                  child: Icon(
                                                    Icons.close_rounded,
                                                    color: Colors.white,
                                                    size: 14,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                )
              : InkWell(
                  onTap: _pickImages,
                  child: SizedBox(
                    height: 152,
                    width: double.infinity,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.image_outlined,
                            size: 32,
                            color: Color(0xFF6B5A8E),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '添加一张打卡图',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '可以是风景，也可以是你的瞬间',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: Colors.grey[500],
                            ),
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

  Widget _buildLocationForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF5F3FA),
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _locationController,
            style: const TextStyle(color: Colors.black87),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索或选择地点...',
              hintStyle: TextStyle(color: Colors.grey[400]),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(left: 6, right: 6),
                child: Icon(
                  Icons.place_rounded,
                  size: 22,
                  color: Color(0xFF6B5A8E),
                ),
              ),
              suffixIcon: InkWell(
                onTap: _isLocatingByGps ? null : _locateCurrentPointByGps,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: _isLocatingByGps
                      ? const CupertinoActivityIndicator(radius: 10)
                      : const Icon(
                          Icons.gps_fixed_rounded,
                          size: 20,
                          color: Colors.black54,
                        ),
                ),
              ),
            ),
            onChanged: (value) {
              final point = _currentPoint;
              if (point == null) return;
              setState(() {
                point.locationName = value;
              });
              _onLocationInputChanged(value);
            },
            onSubmitted: _onLocationSubmitted,
          ),
        ),
        if (_suggestions.isNotEmpty || _isSearchingPoi) ...[
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: _suggestions.isNotEmpty
                ? ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final tip = _suggestions[index];
                      final name = (tip['name'] ?? '').toString().trim();
                      final district =
                          (tip['district'] ?? '').toString().trim();
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _selectInputTip(tip),
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F3FA),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.grey.shade200,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name.isNotEmpty ? name : '未命名地点',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
                                if (district.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    district,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: CupertinoActivityIndicator(radius: 10),
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  /// 沉浸式多行编辑器：无外层盒子、无图标、无边框。
  Widget _buildNoteEditor() {
    return TextField(
      controller: _noteController,
      focusNode: _noteFocusNode,
      keyboardType: TextInputType.multiline,
      minLines: 3,
      maxLines: null,
      textInputAction: TextInputAction.newline,
      style: const TextStyle(
        color: Colors.black87,
        fontSize: 15,
        height: 1.6,
      ),
      decoration: InputDecoration(
        hintText: '写下你在这个地点的想法、感受...',
        hintStyle: TextStyle(
          color: Colors.grey[400],
          fontSize: 15,
          height: 1.6,
        ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 20,
        ),
      ),
      onChanged: (value) {
        final point = _currentPoint;
        if (point == null) return;
        point.note = value;
      },
    );
  }

  void _onLocationInputChanged(String value) {
    final text = value.trim();
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (text.isEmpty) {
      if (!mounted) return;
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      final api = context.read<ApiClient>();
      final tips = await api.getInputTips(text);
      if (!mounted) return;
      if (_locationController.text.trim() != text) return;
      setState(() => _suggestions = tips);
    });
  }

  Future<void> _onLocationSubmitted(String value) async {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    final text = value.trim();
    if (text.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _isSearchingPoi = true;
      _suggestions = [];
    });
    final api = context.read<ApiClient>();
    final results = await api.searchAmapPois(text);
    if (!mounted) return;
    setState(() {
      _isSearchingPoi = false;
    });
    if (results.isNotEmpty) {
      _selectPoiResult(results.first);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('未找到匹配地点')),
    );
  }

  /// 选中输入提示项：更新地名、坐标、地图镜头（zoom 15）。
  void _selectInputTip(Map<String, dynamic> tip) {
    final point = _currentPoint;
    if (point == null) return;
    final name = (tip['name'] ?? '').toString().trim();
    final location = (tip['location'] ?? '').toString().trim();
    final parts = location.split(',');
    if (parts.length != 2) return;
    final lng = double.tryParse(parts[0].trim());
    final lat = double.tryParse(parts[1].trim());
    if (lng == null || lat == null) return;
    final coordinate = LatLng(lat, lng);

    if (_debounce?.isActive ?? false) _debounce!.cancel();
    setState(() {
      point.coordinate = coordinate;
      point.locationName = name.isNotEmpty ? name : '未命名地点';
      _locationController.text = point.locationName;
      _locationController.selection = TextSelection.fromPosition(
        TextPosition(offset: _locationController.text.length),
      );
      _suggestions = [];
    });
    FocusScope.of(context).unfocus();
    _mapController.move(coordinate, 15.0);
    _debugPrintCheckInPoints();
  }

  void _selectPoiResult(Map<String, dynamic> poi) {
    final point = _currentPoint;
    if (point == null) return;
    final name = (poi['name'] ?? '').toString().trim();
    final location = (poi['location'] ?? '').toString().trim();
    final parts = location.split(',');
    if (parts.length != 2) return;
    final lng = double.tryParse(parts[0].trim());
    final lat = double.tryParse(parts[1].trim());
    if (lng == null || lat == null) return;
    final coordinate = LatLng(lat, lng);

    if (_debounce?.isActive ?? false) _debounce!.cancel();
    setState(() {
      point.coordinate = coordinate;
      point.locationName = name.isNotEmpty ? name : '未命名地点';
      _locationController.text = point.locationName;
      _locationController.selection = TextSelection.fromPosition(
        TextPosition(offset: _locationController.text.length),
      );
      _suggestions = [];
      _isSearchingPoi = false;
    });
    FocusScope.of(context).unfocus();
    _mapController.move(coordinate, _mapController.camera.zoom);
    _debugPrintCheckInPoints();
  }

}

/// 自下而上的平滑页面过渡动画，供 Navigator.push 使用。
PageRoute<T> buildAddLocationCardRoute<T>() {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondaryAnimation) =>
        const AddLocationCardPage(),
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      final offsetTween =
          Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero);
      final opacityTween = Tween<double>(begin: 0, end: 1);

      return SlideTransition(
        position: offsetTween.animate(curved),
        child: FadeTransition(
          opacity: opacityTween.animate(curved),
          child: child,
        ),
      );
    },
  );
}



