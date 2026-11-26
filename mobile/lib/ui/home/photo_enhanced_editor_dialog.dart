import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';

class PhotoEnhancedEditorDialog extends StatefulWidget {
  const PhotoEnhancedEditorDialog({
    super.key,
    required this.photoId,
    required this.imageProvider,
  });

  final int photoId;
  final ImageProvider<Object> imageProvider;

  @override
  State<PhotoEnhancedEditorDialog> createState() =>
      _PhotoEnhancedEditorDialogState();
}

class _PhotoEnhancedEditorDialogState
    extends State<PhotoEnhancedEditorDialog> {
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorText;

  late final TextEditingController _descriptionController;
  late final TextEditingController _peopleController;
  late final TextEditingController _locationController;
  late final TextEditingController _takenAtController;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController();
    _peopleController = TextEditingController();
    _locationController = TextEditingController();
    _takenAtController = TextEditingController();

    _loadEnhancedWithRetry();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _peopleController.dispose();
    _locationController.dispose();
    _takenAtController.dispose();
    super.dispose();
  }

  Future<void> _loadEnhancedWithRetry() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    final api = context.read<ApiClient>();
    const maxAttempts = 30;
    const interval = Duration(milliseconds: 600);

    Map<String, dynamic>? lastData;
    for (int i = 0; i < maxAttempts; i++) {
      try {
        final data = await api.getPhotoEnhanced(widget.photoId);
        lastData = data;

        final desc = (data['description'] as String?)?.trim();
        // description 作为“生成完成”的信号（people/time/location 默认值也会很快返回）
        if (desc != null && desc.isNotEmpty) {
          _applyLoadedData(data);
          return;
        }

        // 如果没有 description，但至少有 location/time，也允许展示并让你手动编辑描述
        // （不过你说想等生成描述，我们这里仍会继续重试一段时间）
        if (i == maxAttempts - 1) {
          _applyLoadedData(data);
          return;
        }
      } catch (e) {
        _errorText = e.toString();
        if (i == maxAttempts - 1) break;
      }

      await Future.delayed(interval);
    }

    if (lastData != null) {
      _applyLoadedData(lastData);
    }

    setState(() => _isLoading = false);
  }

  void _applyLoadedData(Map<String, dynamic> data) {
    final peopleRaw = data['person_names'];
    final people = peopleRaw is List
        ? peopleRaw.map((e) => e.toString()).toList()
        : const <String>[];

    final location = (data['location'] as String?);

    final takenRaw = data['taken_at'];
    DateTime? taken;
    if (takenRaw is String) {
      taken = DateTime.tryParse(takenRaw);
    } else if (takenRaw is num) {
      taken = DateTime.fromMillisecondsSinceEpoch(takenRaw.toInt());
    }

    final desc = data['description'] as String?;

    setState(() {
      _descriptionController.text = desc ?? '';
      _peopleController.text = people.join(', ');
      _locationController.text = location ?? '';
      _takenAtController.text = taken?.toIso8601String() ?? '';
      _isLoading = false;
      _errorText = null;
    });
  }

  Future<void> _onSave() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    final api = context.read<ApiClient>();

    final peopleText = _peopleController.text.trim();
    final personNames = peopleText.isEmpty
        ? <String>[]
        : peopleText
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final location = _locationController.text.trim();
    final description = _descriptionController.text.trim();

    DateTime? takenAt;
    final takenText = _takenAtController.text.trim();
    if (takenText.isNotEmpty) {
      takenAt = DateTime.tryParse(takenText);
    }

    try {
      await api.patchPhotoEnhanced(
        widget.photoId,
        personNames: personNames,
        takenAt: takenAt,
        location: location,
        description: description,
      );

      // 直接刷新一次展示内容，避免用户编辑后字段没有反映。
      final data = await api.getPhotoEnhanced(widget.photoId);
      _applyLoadedData(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片信息已保存')),
        );
      }
    } catch (e) {
      setState(() => _errorText = e.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '图片详情（#${widget.photoId}）',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 16 / 10,
                  child: Image(
                    image: widget.imageProvider,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) {
                      return Container(
                        color: Colors.grey.shade200,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_errorText != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorText!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.62,
                child: SingleChildScrollView(
                  child: _isLoading
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          child: Column(
                            children: const [
                              SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(strokeWidth: 3),
                              ),
                              SizedBox(height: 12),
                              Text('等待生成图片描述...'),
                            ],
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: _descriptionController,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                labelText: '图片描述',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _peopleController,
                              decoration: const InputDecoration(
                                labelText: '人物（逗号分隔）',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _takenAtController,
                              decoration: const InputDecoration(
                                labelText: '时间（ISO 8601 或可解析字符串）',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _locationController,
                              decoration: const InputDecoration(
                                labelText: '地点',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 44,
                              child: ElevatedButton(
                                onPressed: _isSaving ? null : _onSave,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF6B3DBB),
                                ),
                                child: _isSaving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('保存'),
                              ),
                            ),
                          ],
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

