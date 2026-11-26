import 'dart:ui';
import 'dart:convert';
import 'dart:typed_data'; // 🚨 新增：用于跨平台处理图片字节

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // 🚨 新增：用于 kIsWeb
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../services/api_client.dart';
import 'photo_enhanced_editor_dialog.dart';

enum BlockType { text, image }

enum UploadStatus {
  pending,
  uploading,
  success,
  error,
}

class StoryBlock {
  StoryBlock._({
    required this.id,
    required this.type,
    this.controller,
    this.focusNode,
    this.imageBytes, // 🚨 改为字节流
    this.imageName,  // 🚨 保存文件名用于上传
    this.uploadProgress,
    this.uploadStatus,
  });

  factory StoryBlock.text({
    required String id,
    String? initialText,
  }) {
    return StoryBlock._(
      id: id,
      type: BlockType.text,
      controller: TextEditingController(text: initialText),
      focusNode: FocusNode(),
    );
  }

  factory StoryBlock.image({
    required String id,
    required Uint8List imageBytes,
    required String imageName,
  }) {
    return StoryBlock._(
      id: id,
      type: BlockType.image,
      imageBytes: imageBytes,
      imageName: imageName,
      uploadProgress: 0.0,
      uploadStatus: UploadStatus.pending,
    );
  }

  final String id;
  final BlockType type;

  // text block
  final TextEditingController? controller;
  final FocusNode? focusNode;

  // image block
  final Uint8List? imageBytes; // 🚨 跨平台图片数据
  final String? imageName;
  
  String? serverId;
  double? uploadProgress; // 0..1
  UploadStatus? uploadStatus;

  String get filename {
    return imageName ?? 'image.jpg';
  }
}

class AddStoryCardPage extends StatefulWidget {
  const AddStoryCardPage({super.key});

  @override
  State<AddStoryCardPage> createState() => _AddStoryCardPageState();
}

class _AddStoryCardPageState extends State<AddStoryCardPage> {
  // 🚨 封面使用字节流渲染
  ImageProvider? _coverImage;
  Uint8List? _coverImageBytes;
  String? _coverImageName;

  final TextEditingController _titleController = TextEditingController();

  // Notion 风格块编辑器（图文混排）
  final List<StoryBlock> _blocks = [];
  final ImagePicker _picker = ImagePicker();

  bool _isProcessingUploadQueue = false;

  // 封面上传状态（不阻塞发布）
  bool _isUploadingCover = false;
  double _coverUploadProgress = 0.0;
  String? _coverServerId;

  // AI 悬浮交互
  bool _showAIInput = false;
  final TextEditingController _aiPromptController = TextEditingController();
  final FocusNode _aiFocusNode = FocusNode();

  int _blockIdSeed = 0;

  String _newBlockId() {
    _blockIdSeed += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-${_blockIdSeed}';
  }

  Future<void> _onPublish() async {
    if (!mounted) return;

    final title = _titleController.text.trim();

    final buffer = StringBuffer();
    final imagePhotoIds = <int>[];
    int imageIndex = 0;

    for (final b in _blocks) {
      if (b.type == BlockType.text) {
        final t = (b.controller?.text ?? '').trim();
        if (t.isEmpty) continue;
        buffer.writeln(t);
        continue;
      }

      if (b.type == BlockType.image) {
        final sid = (b.serverId ?? '').trim();
        if (sid.isEmpty) continue;
        final pid = int.tryParse(sid);
        if (pid == null) continue;
        imagePhotoIds.add(pid);
        buffer.writeln('[IMG_$imageIndex]');
        imageIndex += 1;
      }
    }

    final content = buffer.toString().trim();

    if (title.isEmpty || content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('标题和正文不能为空')),
      );
      return;
    }

    final images = _imageBlocks();
    final hasUnfinishedUpload = images.any(
      (b) =>
          b.uploadStatus != UploadStatus.success ||
          (b.serverId == null || b.serverId!.trim().isEmpty),
    );
    if (hasUnfinishedUpload) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请等待所有图片上传完成后再发布')),
      );
      return;
    }

    final coverId = int.tryParse((_coverServerId ?? '').trim());
    final estimatedMinutes = _estimateReadingMinutes(_plainTextFromBlocks().trim());

    try {
      final api = context.read<ApiClient>();
      await api.createStoryArticle(
        title: title,
        content: content,
        coverPhotoId: coverId,
        imagePhotoIds: imagePhotoIds,
        readingMinutes: estimatedMinutes,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败：$e')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _blocks.add(StoryBlock.text(id: _newBlockId()));
  }

  void _requestFocusSafely(FocusNode? node) {
    if (node == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (node.hasFocus) return;
      try {
        node.requestFocus();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (final b in _blocks) {
      b.controller?.dispose();
      b.focusNode?.dispose();
    }
    _aiPromptController.dispose();
    _aiFocusNode.dispose();
    super.dispose();
  }

  void _onPickCover() {
    _pickCropAndUploadCover();
  }

  // 🚨 修改：选封面改为读取字节流
  Future<void> _pickCropAndUploadCover() async {
    try {
      final picked = await _picker.pickImage(imageQuality: 92, source: ImageSource.gallery);
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final cropped = await _showCoverCropperPlaceholder(context, bytes);
      if (cropped == null) return;

      if (!mounted) return;
      setState(() {
        _coverImageBytes = cropped;
        _coverImageName = picked.name;
        _coverImage = MemoryImage(cropped); // 使用 MemoryImage
        _isUploadingCover = true;
        _coverUploadProgress = 0.0;
        _coverServerId = null;
      });

      // 后台上传：不阻塞用户继续编辑/发布
      _uploadCoverInBackground(cropped, picked.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择封面失败：$e')),
      );
    }
  }

  // 🚨 修改：后台上传封面
  Future<void> _uploadCoverInBackground(Uint8List coverBytes, String filename) async {
    try {
      final api = context.read<ApiClient>();
      
      // 注意：你需要修改 ApiClient，让它支持直接从 Bytes 上传。
      // 否则在 Web 端依然无法上传。
      final result = await api.uploadCoverFromBytes(
        coverBytes,
        filename,
        onSendProgress: (sent, total) {
          if (!mounted) return;
          if (total <= 0) return;
          setState(() {
            _coverUploadProgress = (sent / total).clamp(0.0, 1.0);
          });
        },
      );

      if (!mounted) return;
      final cover = result['cover'];
      final id = cover is Map ? cover['id'] : null;
      setState(() {
        _coverServerId = id?.toString();
        _coverUploadProgress = 1.0;
        _isUploadingCover = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isUploadingCover = false;
      });
    }
  }

  // 🚨 修改：裁切占位改为接收和返回字节流
  Future<Uint8List?> _showCoverCropperPlaceholder(BuildContext context, Uint8List bytes) async {
    return showDialog<Uint8List?>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return _CoverCropperDialogPlaceholder(imageBytes: bytes);
      },
    );
  }

  Future<void> _onAISend() async {
    final allImageBlocks =
        _blocks.where((b) => b.type == BlockType.image).toList();
    final hasUnfinishedUpload = allImageBlocks.any(
      (b) =>
          b.uploadStatus != UploadStatus.success ||
          (b.serverId?.trim().isEmpty ?? true),
    );
    if (hasUnfinishedUpload) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请等待所有图片上传完成后再使用 AI 辅助')),
      );
      return;
    }

    final validImageBlocks = List<StoryBlock>.from(allImageBlocks);
    validImageBlocks.sort((a, b) {
      final aIdRaw = a.serverId!.trim();
      final bIdRaw = b.serverId!.trim();
      final aId = int.tryParse(aIdRaw);
      final bId = int.tryParse(bIdRaw);
      if (aId != null && bId != null) return aId.compareTo(bId);
      return aIdRaw.compareTo(bIdRaw);
    });

    final existingIds = validImageBlocks.map((b) => b.serverId!).join(',');

    final rawUserPrompt = _aiPromptController.text.trim();
    if (rawUserPrompt.isEmpty) return;

    FocusScope.of(context).unfocus();

    final count = validImageBlocks.length;
    final enhancedPrompt = '''
用户指令：$rawUserPrompt

【强制排版要求】：你现在必须同时扮演一个排版大师。根据【照片细节】中提供的 $count 张图片的描述，写一篇长文。
请在生成的文本段落之间，挑选合适的上下文位置插入图片占位符。占位符格式严格为 [IMG_0], [IMG_1]... 直到 [IMG_${count - 1}]。
注意：[IMG_0] 代表【照片细节】中的第一张图，[IMG_1] 代表第二张，依此类推。请确保图文并茂，图片和上下文内容强相关，绝对不要把所有占位符连续堆叠在一起！
''';

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    var closedLoading = false;
    try {
      final api = context.read<ApiClient>();
      final baseUrl = api.base;
      final uri = Uri.parse('$baseUrl/api/ai/generate-story');

      final request = http.MultipartRequest('POST', uri);
      request.fields['user_prompt'] = enhancedPrompt.trim();
      request.fields['time_context'] = DateTime.now().toString();
      request.fields['existing_text'] = _plainTextFromBlocks();
      request.fields['existing_image_ids'] = existingIds;

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);

      if (!mounted) return;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = response.body.isNotEmpty
            ? response.body
            : '${response.statusCode} ${response.reasonPhrase}';
        throw Exception(detail);
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final generatedText = (body['generated_text'] as String?)?.trim() ?? '';

      final newBlocks = _rebuildBlocksFromGeneratedText(
        generatedText: generatedText,
        existingImageBlocks: validImageBlocks,
      );

      if (!mounted) return;
      Navigator.of(context).pop();
      closedLoading = true;

      setState(() {
        _disposeTextBlocks(_blocks);
        _blocks
          ..clear()
          ..addAll(newBlocks);
        _showAIInput = false;
        _aiPromptController.clear();
      });
      _aiFocusNode.unfocus();
    } catch (e) {
      if (!mounted) return;
      if (!closedLoading) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('AI 生成失败：$e')),
      );
    }
  }

  List<StoryBlock> _rebuildBlocksFromGeneratedText({
    required String generatedText,
    required List<StoryBlock> existingImageBlocks,
  }) {
    final uuid = const Uuid();
    final text = generatedText.trim();
    if (text.isEmpty) {
      return [StoryBlock.text(id: uuid.v4(), initialText: '')];
    }

    final reg = RegExp(r'\[IMG_(\d+)\]');
    final newBlocks = <StoryBlock>[];

    int cursor = 0;
    for (final m in reg.allMatches(text)) {
      if (m.start > cursor) {
        final seg = text.substring(cursor, m.start).trim();
        if (seg.isNotEmpty) {
          newBlocks.add(StoryBlock.text(id: uuid.v4(), initialText: seg));
        }
      }

      final rawIndex = m.group(1);
      final idx = rawIndex == null ? null : int.tryParse(rawIndex);
      if (idx != null && idx >= 0 && idx < existingImageBlocks.length) {
        newBlocks.add(existingImageBlocks[idx]);
      }

      cursor = m.end;
    }

    if (cursor < text.length) {
      final seg = text.substring(cursor).trim();
      if (seg.isNotEmpty) {
        newBlocks.add(StoryBlock.text(id: uuid.v4(), initialText: seg));
      }
    }

    if (newBlocks.isEmpty) {
      return [StoryBlock.text(id: uuid.v4(), initialText: text)];
    }

    return newBlocks;
  }

  void _disposeTextBlocks(List<StoryBlock> blocks) {
    for (final b in blocks) {
      if (b.type != BlockType.text) continue;
      b.controller?.dispose();
      b.focusNode?.dispose();
    }
  }

  void _openAIInputBar() {
    if (!mounted) return;
    setState(() {
      _showAIInput = true;
    });
    _requestFocusSafely(_aiFocusNode);
  }

  void _closeAIInputBar() {
    if (!mounted) return;
    setState(() {
      _showAIInput = false;
      _aiPromptController.clear();
    });
    _aiFocusNode.unfocus();
  }

  int _estimateReadingMinutes(String text) {
    if (text.isEmpty) return 1;
    final words = text.trim().split(RegExp(r'\s+')).length;
    final minutes = (words / 250).ceil();
    return minutes.clamp(1, 60);
  }

  String _plainTextFromBlocks() {
    final buffer = StringBuffer();
    for (final b in _blocks) {
      if (b.type != BlockType.text) continue;
      final t = b.controller?.text ?? '';
      if (t.trim().isEmpty) continue;
      buffer.writeln(t);
    }
    return buffer.toString();
  }

  Widget _buildGlassCover(ThemeData theme) {
    const radius = 28.0;
    final shadow = BoxShadow(
      color: Colors.black.withOpacity(0.04),
      blurRadius: 26,
      offset: const Offset(0, 12),
    );

    final cover = _coverImage;
    final coverChild = cover == null
        ? _CoverPlaceholder(theme: theme)
        : Image(
            image: cover,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: _onPickCover,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 240,
              decoration: BoxDecoration(
                color: _coverImage == null
                    ? const Color(0xFF8E5CFF).withOpacity(0.045)
                    : Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(radius),
                boxShadow: [shadow],
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius),
                      child: coverChild,
                    ),
                  ),
                  if (_isUploadingCover)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 14,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: _coverUploadProgress == 0 ? null : _coverUploadProgress,
                          backgroundColor: Colors.black.withOpacity(0.08),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8E5CFF)),
                          minHeight: 4,
                        ),
                      ),
                    ),
                  if (!_isUploadingCover && (_coverServerId?.trim().isNotEmpty ?? false))
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.34),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '已上传',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
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

  List<StoryBlock> _imageBlocks() {
    return _blocks.where((b) => b.type == BlockType.image).toList(growable: false);
  }

  Widget _buildImageProgressCarousel(ThemeData theme) {
    final images = _imageBlocks();
    if (images.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 86,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final b = images[index];
          final p = (b.uploadProgress ?? 0.0).clamp(0.0, 1.0);
          final st = b.uploadStatus ?? UploadStatus.pending;
          final showProgress = st == UploadStatus.uploading || st == UploadStatus.pending;
          final progressColor = switch (st) {
            UploadStatus.success => Colors.green,
            UploadStatus.error => Colors.red,
            _ => const Color(0xFF8E5CFF),
          };

          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                final sid = (b.serverId ?? '').trim();
                final ready = st == UploadStatus.success &&
                    sid.isNotEmpty &&
                    int.tryParse(sid) != null;
                if (!ready) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请等待图片上传完成后再编辑')),
                  );
                  return;
                }

                final photoId = int.parse(sid);
                final bytes = b.imageBytes;
                if (bytes == null) return;

                final ImageProvider<Object> imageProvider = MemoryImage(bytes);

                await showDialog<void>(
                  context: context,
                  builder: (_) => PhotoEnhancedEditorDialog(
                    photoId: photoId,
                    imageProvider: imageProvider,
                  ),
                );
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    SizedBox(
                      width: 86,
                      height: 86,
                      child: () {
                        final bytes = b.imageBytes;
                        if (bytes == null) {
                          return Container(color: Colors.black.withOpacity(0.04));
                        }
                        // 🚨 修改：使用 Image.memory 渲染
                        return Image.memory(
                          bytes,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Container(color: Colors.black.withOpacity(0.04)),
                        );
                      }(),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: SizedBox(
                        height: 4,
                        child: showProgress
                            ? LinearProgressIndicator(
                                value: st == UploadStatus.pending ? null : p,
                                backgroundColor: Colors.black.withOpacity(0.08),
                                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                                minHeight: 4,
                              )
                            : LinearProgressIndicator(
                                value: 1.0,
                                backgroundColor: Colors.black.withOpacity(0.08),
                                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                                minHeight: 4,
                              ),
                      ),
                    ),
                    if (st == UploadStatus.error)
                      Positioned.fill(
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _processUploadQueue,
                            child: Container(
                              color: Colors.black.withOpacity(0.18),
                              child: const Center(
                                child: Icon(Icons.refresh_rounded, color: Colors.white),
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
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemCount: images.length,
      ),
    );
  }

  Widget _buildStoryCanvas(ThemeData theme) {
    final textStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 16,
      height: 1.8,
      color: Colors.black87,
    );

    final hintStyle = theme.textTheme.bodyLarge?.copyWith(
      fontSize: 16,
      height: 1.8,
      color: Colors.black.withOpacity(0.35),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in _blocks)
          if (b.type == BlockType.text)
            () {
              if (b.controller == null || b.focusNode == null) {
                return const SizedBox.shrink();
              }
              return Padding(
                key: ValueKey('block-${b.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: b.controller,
                  focusNode: b.focusNode,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  style: textStyle,
                  decoration: InputDecoration(
                    hintText: '把散落的瞬间拼成一段故事...',
                    hintStyle: hintStyle,
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              );
            }()
          else
            Padding(
              key: ValueKey('block-${b.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () async {
                          final st = b.uploadStatus ?? UploadStatus.pending;
                          final sid = (b.serverId ?? '').trim();
                          final ready = st == UploadStatus.success &&
                              sid.isNotEmpty &&
                              int.tryParse(sid) != null;
                          if (!ready) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('请等待图片上传完成后再编辑')),
                            );
                            return;
                          }

                          final photoId = int.parse(sid);
                          final bytes = b.imageBytes;
                          if (bytes == null) return;
                          
                          final ImageProvider<Object> imageProvider = MemoryImage(bytes);

                          await showDialog<void>(
                            context: context,
                            builder: (_) => PhotoEnhancedEditorDialog(
                              photoId: photoId,
                              imageProvider: imageProvider,
                            ),
                          );
                        },
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: () {
                            final bytes = b.imageBytes;
                            if (bytes == null) {
                              return Container(color: Colors.black.withOpacity(0.04));
                            }
                            // 🚨 修改：使用 Image.memory 渲染
                            return Image.memory(
                              bytes,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  Container(color: Colors.black.withOpacity(0.04)),
                            );
                          }(),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.35),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.close_rounded),
                        color: Colors.white,
                        onPressed: () => _removeBlockById(b.id),
                        tooltip: '移除图片',
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  void _removeBlockById(String id) {
    final idx = _blocks.indexWhere((e) => e.id == id);
    if (idx == -1) return;
    final removed = _blocks.removeAt(idx);
    removed.controller?.dispose();
    removed.focusNode?.dispose();
    if (mounted) setState(() {});
  }

  int _currentFocusedTextBlockIndex() {
    for (int i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      if (b.type != BlockType.text) continue;
      if (b.focusNode?.hasFocus == true) return i;
    }
    return -1;
  }

  Future<void> _onInsertImage() async {
    try {
      final picked = await _picker.pickMultiImage(imageQuality: 92);
      if (picked.isEmpty) return;

      final insertAfter = _currentFocusedTextBlockIndex();
      final insertIndex = insertAfter == -1 ? _blocks.length : insertAfter + 1;

      final List<StoryBlock> toInsert = [];
      for (final f in picked) {
        final bytes = await f.readAsBytes();
        // 🚨 修改：传入 Bytes
        toInsert.add(StoryBlock.image(id: _newBlockId(), imageBytes: bytes, imageName: f.name));
        toInsert.add(StoryBlock.text(id: _newBlockId()));
      }

      setState(() {
        _blocks.insertAll(insertIndex, toInsert);
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final lastText = toInsert.lastWhere(
          (e) => e.type == BlockType.text,
          orElse: () => _blocks.isNotEmpty ? _blocks.last : toInsert.last,
        );
        _requestFocusSafely(lastText.focusNode);
      });

      _processUploadQueue();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择图片失败：$e')),
      );
    }
  }

  Future<void> _processUploadQueue() async {
    if (_isProcessingUploadQueue) return;
    _isProcessingUploadQueue = true;
    try {
      while (mounted) {
        final pending = _blocks
            .where(
              (b) =>
                  b.type == BlockType.image &&
                  (b.uploadStatus == UploadStatus.pending ||
                      b.uploadStatus == UploadStatus.error) &&
                  (b.serverId == null || b.serverId!.trim().isEmpty) &&
                  b.imageBytes != null,
            )
            .toList();
        if (pending.isEmpty) break;

        final batch = pending.take(5).toList();
        final bytesList = <Uint8List>[];
        final namesList = <String>[];

        for (final b in batch) {
          b.uploadStatus = UploadStatus.uploading;
          b.uploadProgress = 0.0;
          final bytes = b.imageBytes;
          if (bytes == null || bytes.isEmpty) {
            b.uploadStatus = UploadStatus.error;
            continue;
          }
          bytesList.add(bytes);
          namesList.add(b.filename);
        }
        if (!mounted) return;
        setState(() {});
        if (bytesList.isEmpty) continue;

        try {
          final client = context.read<ApiClient>();
          
          // 🚨 重要提示：你需要修改你的 ApiClient，增加一个如下方法：
          // Future<Map<String, dynamic>> uploadPhotosBatchFromBytes(List<Uint8List> bytesList, List<String> names, {Function(int, int)? onSendProgress})
          // 否则在 Web 端这里将无法上传！
          
          final result = await client.uploadPhotosBatchFromBytes(
            bytesList,
            namesList,
            onSendProgress: (sent, total) {
              if (!mounted) return;
              final p = total <= 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
              setState(() {
                for (final b in batch) {
                  if (b.uploadStatus == UploadStatus.uploading) {
                    b.uploadProgress = p;
                  }
                }
              });
            },
          );

          final added = (result['added'] as List<dynamic>? ?? const []);
          final dup = (result['duplicates'] as List<dynamic>? ?? const []);

          final used = <StoryBlock>{};
          void apply(dynamic item) {
            if (item is! Map) return;
            final id = item['id'];
            final original = item['original_filename']?.toString();
            if (id == null) return;
            if (original == null || original.trim().isEmpty) return;
            
            final target = batch.firstWhere(
              (e) => !used.contains(e) && e.filename == original,
              orElse: () => batch.firstWhere((e) => !used.contains(e), orElse: () => StoryBlock.image(id: '_', imageBytes: Uint8List(0), imageName: '')),
            );
            if (target.imageBytes == null) return;
            used.add(target);
            target.serverId = id.toString();
            target.uploadStatus = UploadStatus.success;
            target.uploadProgress = 1.0;
          }

          for (final item in added) { apply(item); }
          for (final item in dup) { apply(item); }

          for (final b in batch) {
            if (b.uploadStatus == UploadStatus.uploading) {
              b.uploadStatus = UploadStatus.error;
            }
          }
        } catch (_) {
          for (final b in batch) {
            if (b.uploadStatus == UploadStatus.uploading) {
              b.uploadStatus = UploadStatus.error;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final estimatedMin = _estimateReadingMinutes(_plainTextFromBlocks());

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        title: const Text(
          '写一篇故事',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _onPublish,
            child: Text(
              '发布',
              style: theme.textTheme.labelLarge?.copyWith(
                color: const Color(0xFF6B3DBB),
                fontWeight: FontWeight.w700,
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
                padding: const EdgeInsets.only(top: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildGlassCover(theme),
                    const SizedBox(height: 12),
                    _buildImageProgressCarousel(theme),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _titleController,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                                color: Colors.black87,
                              ),
                              decoration: const InputDecoration(
                                hintText: '输入故事标题...',
                                border: InputBorder.none,
                                isCollapsed: true,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_photo_alternate_rounded),
                            color: const Color(0xFF6B3DBB),
                            onPressed: _onInsertImage,
                            tooltip: '插入图片',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildStoryCanvas(theme),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        '自动计算阅读时间约 $estimatedMin min',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.black.withOpacity(0.45),
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 200),
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

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            shaderCallback: (bounds) {
              return const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF8E5CFF),
                  Color(0xFF6B3DBB),
                ],
              ).createShader(bounds);
            },
            child: Icon(
              Icons.image_outlined,
              size: 34,
              color: Colors.white.withOpacity(0.95),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '添加一张封面图',
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: Colors.black.withOpacity(0.78),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '可以是城市一角，也可以是故事主角',
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.black.withOpacity(0.48),
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// 🚨 修改：裁切占位改为接收和返回字节流
class _CoverCropperDialogPlaceholder extends StatefulWidget {
  const _CoverCropperDialogPlaceholder({required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<_CoverCropperDialogPlaceholder> createState() =>
      _CoverCropperDialogPlaceholderState();
}

class _CoverCropperDialogPlaceholderState
    extends State<_CoverCropperDialogPlaceholder> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = const [
      'Notion Banner (3:1)',
      '卡片封面 (16:9)',
      '方形 (1:1)',
      '自由裁切',
    ];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.92),
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 30,
                  offset: const Offset(0, 16),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '裁切封面（占位）',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: AspectRatio(
                    aspectRatio: _selected == 0
                        ? 3 / 1
                        : _selected == 1
                            ? 16 / 9
                            : _selected == 2
                                ? 1
                                : 16 / 9,
                    // 🚨 修改：使用 Image.memory 渲染
                    child: Image.memory(
                      widget.imageBytes,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.black.withOpacity(0.04)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemBuilder: (context, index) {
                      final selected = index == _selected;
                      return ChoiceChip(
                        label: Text(labels[index]),
                        selected: selected,
                        onSelected: (_) => setState(() => _selected = index),
                        selectedColor: const Color(0xFF8E5CFF).withOpacity(0.12),
                        backgroundColor: Colors.black.withOpacity(0.04),
                        labelStyle: theme.textTheme.labelMedium?.copyWith(
                          color: selected
                              ? const Color(0xFF6B3DBB)
                              : Colors.black.withOpacity(0.7),
                          fontWeight: FontWeight.w700,
                        ),
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: selected
                                ? const Color(0xFF6B3DBB).withOpacity(0.18)
                                : Colors.transparent,
                            width: 0.8,
                          ),
                        ),
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemCount: labels.length,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(null),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          // 🚨 修改：返回字节流
                          Navigator.of(context).pop(widget.imageBytes);
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF6B3DBB),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('使用此裁切'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '提示：当前为占位裁切器，后续接入裁切库后将生成真实裁切文件。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black.withOpacity(0.45),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}