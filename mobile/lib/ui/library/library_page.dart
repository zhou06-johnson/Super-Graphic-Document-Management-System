import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../compo_wave_background.dart';
import 'all_photos_view.dart';
import 'library_sort_mode.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _refreshTick = 0;
  bool _uploading = false;
  double _uploadProgress = 0;

  // 当图库进入多选模式时隐藏右下角的 + 号按钮。
  bool _inSelectionMode = false;

  void _handleSelectionModeChanged(bool value) {
    if (_inSelectionMode == value) return;
    setState(() {
      _inSelectionMode = value;
    });
  }

  Future<void> _chooseImport() async {
    if (_uploading) return;
    final importVideo = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('导入照片'),
              onTap: () => Navigator.pop(sheetContext, false),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('导入视频'),
              onTap: () => Navigator.pop(sheetContext, true),
            ),
          ],
        ),
      ),
    );
    if (!mounted || importVideo == null) return;
    if (importVideo) {
      await _pickAndUploadVideo();
    } else {
      await _pickAndUpload();
    }
  }

  Future<void> _pickAndUploadVideo() async {
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (!mounted || file == null || _uploading) return;
    final api = context.read<ApiClient>();
    setState(() => _uploading = true);
    try {
      await api.uploadLibraryVideo(File(file.path), file.name);
      if (!mounted) return;
      setState(() => _refreshTick++);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('视频已添加到图库，正在后台分析')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('视频导入失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    if (_uploading) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    final picker = ImagePicker();
    final pickedList = await picker.pickMultiImage(imageQuality: 92);
    if (!mounted || pickedList.isEmpty) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });

    if (mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Expanded(child: Text('正在上传...')),
                ],
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _uploadProgress == 0 ? null : _uploadProgress,
              ),
            ],
          ),
        ),
      );
    }

    try {
      final api = context.read<ApiClient>();
      final files = pickedList.map((x) => File(x.path)).toList();
      final result = await api.uploadPhotosBatch(
        files,
        onSendProgress: (sent, total) {
          if (!mounted || total == 0) return;
          setState(() {
            _uploadProgress = sent / total;
          });
        },
      );

      if (!mounted) return;
      if (navigator.canPop()) {
        navigator.pop();
      }

      setState(() {
        _refreshTick++;
      });

      final tabController = DefaultTabController.maybeOf(context);
      tabController?.animateTo(0);

      final added = result['added'] as List<dynamic>? ?? [];
      final duplicates = result['duplicates'] as List<dynamic>? ?? [];
      final addedCount = added.length;
      final dupCount = duplicates.length;

      if (dupCount == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加 $addedCount 张照片')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已添加 $addedCount 张；$dupCount 张与图库重复未添加'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (navigator.canPop()) {
        navigator.pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabIndicator = Theme.of(context).colorScheme.primary;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        appBar: AppBar(
          backgroundColor: kCompoWavePageBase,
          foregroundColor: Colors.black87,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: const Text('图库'),
          bottom: TabBar(
            labelColor: Colors.black87,
            unselectedLabelColor: Colors.black45,
            indicatorColor: tabIndicator,
            tabs: const [
              Tab(text: '时间'),
              Tab(text: '地点'),
              Tab(text: '人物'),
              Tab(text: '视频'),
            ],
          ),
        ),
        body: CompoWaveBackground(
          child: TabBarView(
            children: [
              AllPhotosView(
                refreshTick: _refreshTick,
                sortMode: LibrarySortMode.time,
                onSelectionModeChanged: _handleSelectionModeChanged,
              ),
              AllPhotosView(
                refreshTick: _refreshTick,
                sortMode: LibrarySortMode.location,
                onSelectionModeChanged: _handleSelectionModeChanged,
              ),
              AllPhotosView(
                refreshTick: _refreshTick,
                sortMode: LibrarySortMode.people,
                onSelectionModeChanged: _handleSelectionModeChanged,
              ),
              _LibraryVideos(key: ValueKey(_refreshTick)),
            ],
          ),
        ),
        floatingActionButton: _inSelectionMode
            ? null
            : FloatingActionButton(
                onPressed: _uploading ? null : _chooseImport,
                child: _uploading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
              ),
      ),
    );
  }
}



class _LibraryVideos extends StatefulWidget {
  const _LibraryVideos({super.key});

  @override
  State<_LibraryVideos> createState() => _LibraryVideosState();
}

class _LibraryVideosState extends State<_LibraryVideos> {
  late Future<List<Map<String, dynamic>>> _videos;

  @override
  void initState() {
    super.initState();
    _videos = context.read<ApiClient>().listLibraryVideos();
  }

  Future<void> _refresh() async {
    final next = context.read<ApiClient>().listLibraryVideos();
    setState(() => _videos = next);
    try {
      await next;
    } catch (_) {
      // FutureBuilder renders the request error.
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = context.watch<ApiClient>();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _videos,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: TextButton(onPressed: _refresh, child: const Text('加载失败，重试')));
        }
        final videos = snapshot.data ?? const <Map<String, dynamic>>[];
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (videos.isEmpty) const ListTile(title: Text('点击加号导入视频')),
              for (final item in videos)
                ListTile(
                  leading: item['has_thumbnail'] == true
                      ? Image.network(
                          api.libraryVideoThumbnail(item['id'] as String),
                          width: 56, height: 42, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(Icons.movie),
                        )
                      : const Icon(Icons.movie),
                  title: Text(item['name']?.toString() ?? '视频'),
                  subtitle: Text(switch (item['status']) {
                    'analyzing' => '正在分析',
                    'local' => '待补充 AI 标签',
                    'ready' => ((item['labels'] as Map?)?['tags'] as List? ?? []).join(' · '),
                    _ => '标签暂不可用',
                  }),
                ),
            ],
          ),
        );
      },
    );
  }
}
