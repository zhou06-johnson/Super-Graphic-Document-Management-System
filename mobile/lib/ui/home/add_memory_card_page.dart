import 'dart:ui';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data'; 

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; 
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;

import '../../services/api_client.dart';
import 'photo_enhanced_editor_dialog.dart';

enum UploadStatus {
  pending,
  uploading,
  success,
  error,
}

class UploadableImage {
  UploadableImage({
    required this.localPath,
    this.imageBytes, // 🚨 新增：存储字节流
    this.imageName,  // 🚨 新增：存储文件名
    this.serverId,
    this.progress = 0.0,
    this.status = UploadStatus.pending,
  });

  final String localPath;
  final Uint8List? imageBytes; // 🚨 新增
  final String? imageName;     // 🚨 新增
  String? serverId;
  double progress; // 0.0 ~ 1.0
  UploadStatus status;

  String get filename => imageName ?? localPath.split(RegExp(r'[/\\]')).last;

  bool get isRemote => localPath.startsWith('http://') || localPath.startsWith('https://');
}

class HashtagTextEditingController extends TextEditingController {
  HashtagTextEditingController({String? text}) : super(text: text);

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    if (text.isEmpty) {
      return TextSpan(style: style, text: '');
    }

    final List<InlineSpan> children = [];
    final RegExp exp = RegExp(r'(#[^\s#]+)');
    int currentIndex = 0;

    for (final match in exp.allMatches(text)) {
      if (match.start > currentIndex) {
        children.add(
          TextSpan(
            text: text.substring(currentIndex, match.start),
            style: style,
          ),
        );
      }
      final String hashtag = match.group(0) ?? '';
      children.add(
        TextSpan(
          text: hashtag,
          style: style?.copyWith(
            color: const Color(0xFF8E5CFF),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      currentIndex = match.end;
    }

    if (currentIndex < text.length) {
      children.add(
        TextSpan(
          text: text.substring(currentIndex),
          style: style,
        ),
      );
    }

    return TextSpan(style: style, children: children);
  }
}

class MemoryCard {
  final int? id;
  final String title;
  final String content;
  final List<String> imagePaths;
  final String? createdAt;

  MemoryCard({
    this.id,
    required this.title,
    required this.content,
    required this.imagePaths,
    this.createdAt,
  });

  factory MemoryCard.fromJson(Map<String, dynamic> json) {
    return MemoryCard(
      id: json['id'] as int?,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      imagePaths: (json['image_paths'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      createdAt: json['created_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'image_paths': imagePaths,
      'created_at': createdAt,
    };
  }
}

class AddMemoryCardPage extends StatefulWidget {
  const AddMemoryCardPage({
    super.key,
    this.initialCard,
  });

  final MemoryCard? initialCard;

  @override
  State<AddMemoryCardPage> createState() => _AddMemoryCardPageState();
}

class _AddMemoryCardPageState extends State<AddMemoryCardPage> {
  final List<UploadableImage> _images = [];

  final HashtagTextEditingController _contentController =
      HashtagTextEditingController();

  final ImagePicker _picker = ImagePicker();

  bool _isSubmitting = false;
  bool _isProcessingUploadQueue = false;

  // 新增：AI 输入状态 & 控制
  bool _showAIInput = false;
  final TextEditingController _aiPromptController = TextEditingController();
  final FocusNode _aiFocusNode = FocusNode();

  bool get _hasUploadingImages =>
      _isProcessingUploadQueue ||
      _images.any((e) => e.status == UploadStatus.uploading);

  @override
  void initState() {
    super.initState();
    final initial = widget.initialCard;
    if (initial != null) {
      _contentController.text = initial.content;
      for (final p in initial.imagePaths) {
        final id = _tryExtractServerId(p);
        _images.add(
          UploadableImage(
            localPath: p,
            serverId: id,
            progress: 1.0,
            status: UploadStatus.success,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _contentController.dispose();
    _aiPromptController.dispose();
    _aiFocusNode.dispose();
    super.dispose();
  }

  // 🚨 修改：选择图片并读取字节流
  Future<void> _onPickImage() async {
    try {
      final List<XFile> files = await _picker.pickMultiImage();
      if (files.isEmpty) return;

      final newImages = <UploadableImage>[];
      for (final f in files) {
        final bytes = await f.readAsBytes();
        newImages.add(UploadableImage(
          localPath: f.path,
          imageBytes: bytes, // 保存 bytes 用于预览和上传
          imageName: f.name, // 保存文件名
          progress: 0.0,
          status: UploadStatus.pending,
        ));
      }

      setState(() {
        _images.addAll(newImages);
      });
      await _processUploadQueue();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败：$e')),
      );
    }
  }

  String? _tryExtractServerId(String value) {
    final p = value.trim();
    if (p.isEmpty) return null;
    if (RegExp(r'^\d+$').hasMatch(p)) return p;
    if (!(p.startsWith('http://') || p.startsWith('https://'))) return null;
    try {
      final u = Uri.parse(p);
      final segments = u.pathSegments;
      final photosIdx = segments.indexOf('photos');
      if (photosIdx != -1 && photosIdx + 1 < segments.length) {
        final idSeg = segments[photosIdx + 1];
        if (RegExp(r'^\d+$').hasMatch(idSeg)) return idSeg;
      }
      final m = RegExp(r'(\d+)').firstMatch(p);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<void> _retryUpload(UploadableImage img) async {
    if (!mounted) return;
    setState(() {
      img.serverId = null;
      img.progress = 0.0;
      img.status = UploadStatus.pending;
    });
    await _processUploadQueue();
  }

  // 🚨 修改：批量上传改为调用 ApiClient 的 Bytes 方法
  Future<void> _processUploadQueue() async {
    if (_isProcessingUploadQueue) return;
    _isProcessingUploadQueue = true;
    try {
      while (mounted) {
        final pending = _images
            .where(
              (e) =>
                  e.status == UploadStatus.pending &&
                  !e.isRemote &&
                  e.serverId == null &&
                  e.localPath.trim().isNotEmpty,
            )
            .toList();
        if (pending.isEmpty) break;

        final batch = pending.take(5).toList();
        for (final img in batch) {
          img.status = UploadStatus.uploading;
          img.progress = 0.0;
        }
        if (mounted) setState(() {});

        final client = context.read<ApiClient>();
        final bytesList = <Uint8List>[];
        final namesList = <String>[];
        final existingByName = <String, List<UploadableImage>>{};
        
        String _normalizeFilename(String value) {
          final trimmed = value.trim();
          if (trimmed.isEmpty) return '';
          final base = trimmed.split(RegExp(r'[/\\]')).last.trim();
          return base.toLowerCase();
        }

        for (final img in batch) {
          if (img.imageBytes != null) {
            bytesList.add(img.imageBytes!);
            namesList.add(img.filename);
            final key = _normalizeFilename(img.filename);
            if (key.isNotEmpty) {
              existingByName.putIfAbsent(key, () => []).add(img);
            }
          } else {
            // 兜底：如果是老数据没有 bytes，尝试读本地文件（仅限非 Web）
            try {
              final f = File(img.localPath);
              if (await f.exists()) {
                bytesList.add(await f.readAsBytes());
                namesList.add(img.filename);
                final key = _normalizeFilename(img.filename);
                if (key.isNotEmpty) {
                  existingByName.putIfAbsent(key, () => []).add(img);
                }
              } else {
                img.status = UploadStatus.error;
              }
            } catch (_) {
              img.status = UploadStatus.error;
            }
          }
        }
        
        if (mounted) setState(() {});
        if (bytesList.isEmpty) continue;

        try {
          final result = await client.uploadPhotosBatchFromBytes(
            bytesList,
            namesList,
            onSendProgress: (sent, total) {
              if (!mounted) return;
              final p = total <= 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
              setState(() {
                for (final img in batch) {
                  if (img.status == UploadStatus.uploading) {
                    img.progress = p;
                  }
                }
              });
            },
          );

          final added = (result['added'] as List<dynamic>? ?? const []);
          final dupList = (result['duplicates'] as List<dynamic>? ?? const []);
          final used = <UploadableImage>{};
          
          void _applyUploadResult(dynamic item) {
            if (item is! Map) return;
            final id = item['id'];
            final originalFilename = item['original_filename']?.toString();
            if (id == null) return;
            if (originalFilename == null || originalFilename.trim().isEmpty) return;

            final key = _normalizeFilename(originalFilename);
            if (key.isEmpty) return;
            final candidates = existingByName[key] ?? const <UploadableImage>[];
            final target = candidates.firstWhere(
              (e) => !used.contains(e),
              orElse: () => UploadableImage(localPath: ''),
            );
            if (target.localPath.isEmpty) return;

            used.add(target);
            target.serverId = id.toString();
            target.status = UploadStatus.success;
            target.progress = 1.0;
          }

          for (final item in added) { _applyUploadResult(item); }
          for (final item in dupList) { _applyUploadResult(item); }

          for (final img in batch) {
            if (img.status == UploadStatus.uploading) {
              img.status = UploadStatus.error;
            }
          }
        } catch (_) {
          for (final img in batch) {
            if (img.status == UploadStatus.uploading) {
              img.status = UploadStatus.error;
            }
          }
        } finally {
          if (mounted) setState(() {});
        }
      }
    } finally {
      _isProcessingUploadQueue = false;
    }
  }

  Future<void> _onPublish() async {
    if (_isSubmitting) return;

    if (_hasUploadingImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片正在上传中，请稍后...')),
      );
      return;
    }

    final content = _contentController.text.trim();
    String title;
    if (content.isEmpty) {
      title = '无题瞬间';
    } else {
      final firstLine = content.split('\n').first;
      title = firstLine.length <= 15 ? firstLine : firstLine.substring(0, 15);
    }

    final isEdit = widget.initialCard != null && widget.initialCard!.id != null;

    setState(() {
      _isSubmitting = true;
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const Center(
          child: CircularProgressIndicator(),
        );
      },
    );

    try {
      final baseUrl = context.read<ApiClient>().base;
      final existingIds = _images
          .where((e) => e.status == UploadStatus.success && (e.serverId?.trim().isNotEmpty ?? false))
          .map((e) => e.serverId!.trim())
          .toList();

      final imageUrls = <String>[];
      for (final img in _images) {
        if (img.isRemote) {
          imageUrls.add(img.localPath);
        } else if (img.status == UploadStatus.success && (img.serverId?.trim().isNotEmpty ?? false)) {
          imageUrls.add('$baseUrl/api/photos/${img.serverId!.trim()}/file');
        }
      }

      final card = MemoryCard(
        id: widget.initialCard?.id,
        title: title,
        content: content,
        imagePaths: List<String>.from(imageUrls),
        createdAt: widget.initialCard?.createdAt,
      );

      final payload = <String, dynamic>{
        ...card.toJson(),
        'existing_image_ids': existingIds.join(','),
      };

      final client = context.read<ApiClient>();
      final path = isEdit
          ? '/api/memory-cards/${card.id}'
          : '/api/memory-cards';

      final http.Response response;
      if (isEdit) {
        final uri = client.buildUri(path);
        response = await http.put(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );
      } else {
        final uri = client.buildUri(path);
        response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );
      }

      if (!mounted) return;

      Navigator.of(context).pop(); // 关闭 loading

      if (response.statusCode >= 200 && response.statusCode < 300) {
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('保存失败：${response.statusCode} ${response.reasonPhrase}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('网络请求失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _onAISend() async {
    final userPrompt = _aiPromptController.text.trim();
    if (userPrompt.isEmpty) return;

    final currentText = _contentController.text.trim();

    FocusScope.of(context).unfocus();

    final baseUrl = context.read<ApiClient>().base;
    final uri = Uri.parse('$baseUrl/api/ai/generate-story');

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('AI 正在为你撰写回忆...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final existingIds = _images
          .where((e) => e.status == UploadStatus.success && (e.serverId?.trim().isNotEmpty ?? false))
          .map((e) => e.serverId!.trim())
          .toList();

      final request = http.MultipartRequest('POST', uri);
      request.fields['user_prompt'] = userPrompt;
      request.fields['time_context'] = DateTime.now().toString();
      request.fields['existing_text'] = currentText;
      request.fields['existing_image_ids'] = existingIds.join(',');

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭 Loading

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final generatedText =
            (body['generated_text'] as String?)?.trim() ?? '';
        if (generatedText.isNotEmpty) {
          _contentController.text = generatedText;
        }
        setState(() {
          _showAIInput = false;
          _aiPromptController.clear();
        });
        _aiFocusNode.unfocus();
      } else {
        final detail = response.body.isNotEmpty
            ? response.body
            : '${response.statusCode} ${response.reasonPhrase}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成失败：$detail')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请求失败：$e')),
      );
    }
  }

  void _openAIInputBar() {
    setState(() {
      _showAIInput = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _aiFocusNode.requestFocus();
    });
  }

  void _closeAIInputBar() {
    setState(() {
      _showAIInput = false;
      _aiPromptController.clear();
    });
    _aiFocusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final isEdit = widget.initialCard != null;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          color: Colors.black87,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          isEdit ? '编辑瞬间' : '记录瞬间',
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: TextButton(
              onPressed: (_isSubmitting || _hasUploadingImages) ? null : _onPublish,
              child: Text(
                isEdit ? '更新' : '发布',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF6B3DBB),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 10, left: 16, right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildImageStackCarousel(theme),
                    const SizedBox(height: 24),
                    Text(
                      '记录这瞬间...',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildExpansiveTextField(theme),
                    const SizedBox(height: 180),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: keyboardInset > 0 ? 12.0 : 32.0,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SizeTransition(
                      sizeFactor: animation,
                      axisAlignment: -1.0,
                      child: child,
                    ),
                  );
                },
                child: _showAIInput
                    ? SizedBox(
                        key: const ValueKey('ai-input-bar'),
                        width: double.infinity,
                        child: _AIInputBar(
                          controller: _aiPromptController,
                          focusNode: _aiFocusNode,
                          onSend: _onAISend,
                          onClose: _closeAIInputBar,
                        ),
                      )
                    : Align(
                        key: const ValueKey('ai-floating-button'),
                        alignment: Alignment.centerRight,
                        child: _AIFloatingButton(
                          onTapGenerate: _openAIInputBar,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageStackCarousel(ThemeData theme) {
    if (_images.isEmpty) {
      return GestureDetector(
        onTap: _onPickImage,
        child: Container(
          height: 90.0,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.black.withOpacity(0.04),
          ),
          child: const Center(
            child: Icon(
              Icons.add_photo_alternate_rounded,
              size: 32,
              color: Colors.grey,
            ),
          ),
        ),
      );
    }

    const double itemSize = 90.0;

    return SizedBox(
      height: itemSize,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _images.length + 1,
        padding: EdgeInsets.zero,
        itemBuilder: (context, index) {
          if (index == _images.length) {
            return GestureDetector(
              onTap: _onPickImage,
              child: Container(
                width: itemSize,
                height: itemSize,
                margin: EdgeInsets.only(left: index == 0 ? 0 : 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.black.withOpacity(0.04),
                ),
                child: const Center(
                  child: Icon(
                    Icons.add,
                    size: 32,
                    color: Colors.grey,
                  ),
                ),
              ),
            );
          }

          final img = _images[index];
          return Stack(
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    final sid = img.serverId?.trim();
                    final ready = img.status == UploadStatus.success &&
                        sid != null &&
                        sid.isNotEmpty &&
                        int.tryParse(sid) != null;
                    if (!ready) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请等待图片上传完成后再编辑')),
                      );
                      return;
                    }

                    final photoId = int.parse(sid);
                    final ImageProvider<Object> imageProvider = img.isRemote
                        ? NetworkImage(img.localPath)
                        : (img.imageBytes != null 
                            ? MemoryImage(img.imageBytes!) 
                            : FileImage(File(img.localPath)));

                    await showDialog<void>(
                      context: context,
                      builder: (_) => PhotoEnhancedEditorDialog(
                        photoId: photoId,
                        imageProvider: imageProvider,
                      ),
                    );
                  },
                  child: Container(
                    width: itemSize,
                    height: itemSize,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Column(
                        children: [
                          Expanded(
                            child: img.isRemote
                                ? Image.network(
                                    img.localPath,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) =>
                                        const Center(child: Icon(Icons.broken_image)),
                                  )
                                // 🚨 核心修改：使用 Image.memory 渲染
                                : (img.imageBytes != null
                                    ? Image.memory(
                                        img.imageBytes!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) =>
                                            const Center(child: Icon(Icons.broken_image)),
                                      )
                                    : Image.file(
                                        File(img.localPath),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) =>
                                            const Center(child: Icon(Icons.broken_image)),
                                      )),
                          ),
                          SizedBox(
                            height: 4,
                            child: _buildUploadProgressBar(theme, img),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 6,
                right: 18,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (img.status == UploadStatus.error)
                Positioned.fill(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _retryUpload(img),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.refresh_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildUploadProgressBar(ThemeData theme, UploadableImage img) {
    final purple = const Color(0xFF8E5CFF);
    final v = switch (img.status) {
      UploadStatus.uploading => img.progress.clamp(0.0, 1.0),
      UploadStatus.success => 1.0,
      _ => 0.0,
    };

    final color = switch (img.status) {
      UploadStatus.uploading => purple,
      UploadStatus.success => Colors.green,
      UploadStatus.error => Colors.red,
      _ => Colors.black.withOpacity(0.12),
    };

    if (img.status == UploadStatus.pending) {
      return Container(color: Colors.black.withOpacity(0.06));
    }

    return LinearProgressIndicator(
      value: v,
      backgroundColor: Colors.black.withOpacity(0.08),
      valueColor: AlwaysStoppedAnimation<Color>(color),
      minHeight: 4,
    );
  }

  Widget _buildExpansiveTextField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _contentController,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.6,
            fontSize: 15,
            color: Colors.black.withOpacity(0.9),
          ),
          decoration: InputDecoration(
            hintText:
                '写下这一刻的想法，使用 # 添加标签...\n\n这里几乎没有边界，随意挥洒。',
            hintStyle: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.black.withOpacity(0.35),
            ),
            border: InputBorder.none,
            isCollapsed: true,
          ),
        ),
      ],
    );
  }
}

class _AIFloatingButton extends StatelessWidget {
  const _AIFloatingButton({
    required this.onTapGenerate,
  });

  final VoidCallback onTapGenerate;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
          child: InkWell(
            onTap: onTapGenerate,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.85),
                border: Border.all(
                  color: const Color(0xFF6B3DBB).withOpacity(0.12),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF8E5CFF),
                        Color(0xFFFC6BD6),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.auto_awesome,
                    size: 20,
                    color: Colors.white,
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

class _AIInputBar extends StatelessWidget {
  const _AIInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onSend;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: const Color(0xFF6B3DBB).withOpacity(0.18),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFF8E5CFF),
                      Color(0xFFFC6BD6),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: '告诉 AI 你想怎么写...',
                    hintStyle: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withOpacity(0.35),
                    ),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 14,
                    color: Colors.black.withOpacity(0.9),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.send_rounded),
                color: const Color(0xFF8E5CFF),
                onPressed: () async {
                  await onSend();
                },
                tooltip: '发送给 AI',
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                color: Colors.black.withOpacity(0.45),
                onPressed: onClose,
                tooltip: '关闭 AI 输入',
              ),
            ],
          ),
        ),
      ),
    );
  }
}