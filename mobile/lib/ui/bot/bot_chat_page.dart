import 'dart:ui'; // for BackdropFilter (glassmorphism)
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../compo_wave_background.dart';
import '../chat_ui_state.dart';

/// Bot 会话页，对接后端 /api/ai/chat（SiliconFlow）。
class BotChatPage extends StatefulWidget {
  const BotChatPage({super.key, this.personContext});

  /// 从人物详情页跳转时可传入当前人物名，用于增强 Bot 回复。
  final String? personContext;

  @override
  State<BotChatPage> createState() => _BotChatPageState();
}

class _BotChatPageState extends State<BotChatPage> {
  final List<_ChatMessage> _messages = <_ChatMessage>[
    const _ChatMessage(
      role: ChatRole.assistant,
      content:
          '你好，我是 MemoirsCore 助手。你可以直接通过自然语言让我找照片、生成描述或整理相册。我会自己判断你需要什么功能。',
    ),
  ];
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _loading = false;
  bool _isInputExpanded = false;

  bool _isOpening = false;

  static const Duration _navAnimDuration = Duration(milliseconds: 220);

  Future<void> _openInputAndWaitNav() async {
    if (_isInputExpanded || _isOpening) return;
    _isOpening = true;

    // Trigger capsule nav hide (global).
    context.read<ChatUiState>().setBotInputExpanded(true);

    // Wait until nav finishes sliding down.
    await Future.delayed(_navAnimDuration + const Duration(milliseconds: 20));
    if (!mounted || !_isOpening) return;

    setState(() => _isInputExpanded = true);

    // Tiny delay to ensure TextField is built before requesting focus.
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted || !_isOpening) return;
    _focusNode.requestFocus();
    _isOpening = false;
  }

  Future<void> _closeInputAndWaitNav() async {
    if (!_isInputExpanded && !_isOpening) return;

    // Hide input panel immediately.
    _isOpening = false; // cancel any pending "open" flow
    _focusNode.unfocus();
    setState(() => _isInputExpanded = false);

    // Give the input panel a moment to disappear before showing nav.
    await Future.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    context.read<ChatUiState>().setBotInputExpanded(false);
  }

  @override
  void dispose() {
    if (_isInputExpanded || _isOpening) {
      context.read<ChatUiState>().setBotInputExpanded(false);
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _loading) return;

    setState(() {
      _messages.add(_ChatMessage(role: ChatRole.user, content: text));
      _controller.clear();
      _loading = true;
      _messages.add(
        const _ChatMessage(role: ChatRole.assistant, content: '思考中...'),
      );
    });

    try {
      final api = context.read<ApiClient>();
      final toSend = _messages.sublist(0, _messages.length - 1);
      final list = toSend
          .map((m) => {
                'role': m.role == ChatRole.user ? 'user' : 'assistant',
                'content': m.content,
              })
          .toList();
      final result = await api.botChat(list, personContext: widget.personContext);

      if (!mounted) return;
      setState(() {
        _messages.removeLast();
        _messages.add(_ChatMessage(
          role: ChatRole.assistant,
          content: result.content,
          photos: result.photos,
        ));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.removeLast();
        _messages.add(_ChatMessage(
          role: ChatRole.assistant,
          content: '请求失败：$e',
        ));
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      extendBody: false,
      appBar: AppBar(
        backgroundColor: kCompoWavePageBase,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        title: Text(
          widget.personContext != null && widget.personContext!.isNotEmpty
              ? 'Bot 助手 · ${widget.personContext}'
              : 'Bot 助手',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      // 点击空白处收起键盘；如果输入框没字，也顺便收起输入面板。
      body: CompoWaveBackground(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  FocusScope.of(context).unfocus();
                  if (_controller.text.trim().isEmpty) {
                    _closeInputAndWaitNav();
                  }
                },
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: _isInputExpanded ? 80 : 100,
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg.role == ChatRole.user;
                      return _buildChatBubble(msg, isUser, context);
                    },
                  ),
                ),
              ),
            ),

            // 展开时显示输入面板
            if (_isInputExpanded)
              Align(
                alignment: Alignment.bottomCenter,
                child: _buildBottomArea(context),
              ),

            // 收起时显示悬浮球入口
            if (!_isInputExpanded)
              Positioned(
                right: 20,
                bottom: 100,
                child: FloatingActionButton(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  onPressed: () {
                    _openInputAndWaitNav();
                  },
                  child: const Icon(
                    Icons.chat_bubble_outline,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Modern chat bubble with a subtle "tail" via asymmetric border radius.
  Widget _buildChatBubble(_ChatMessage msg, bool isUser, BuildContext context) {
    final theme = Theme.of(context);
    final api = context.read<ApiClient>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
              child: Icon(
                Icons.smart_toy_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              decoration: BoxDecoration(
                color: isUser ? theme.colorScheme.primary : theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(isUser ? 20 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 20),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    msg.content,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (!isUser && msg.photos.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: msg.photos
                          .where((p) => p.url.trim().isNotEmpty)
                          .map((p) {
                        final u = api.buildUri(p.url).toString();
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            u,
                            width: 120,
                            height: 120,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 120,
                              height: 120,
                              color: Colors.black12,
                              alignment: Alignment.center,
                              child: const Icon(Icons.broken_image_outlined),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom input area with blur glass background.
  Widget _buildBottomArea(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          // Force pure white to avoid any dark/transparent artifacts.
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.9),
            border: Border(
              top: BorderSide(color: Colors.grey.withOpacity(0.2), width: 0.5),
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Choose photo button (kept).
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 28),
                    color: Colors.grey[600],
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      // TODO: choose photo as context
                    },
                  ),
                  const SizedBox(width: 12),
                  // Core input
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: const TextStyle(fontSize: 15, color: Colors.black87),
                        decoration: InputDecoration(
                          hintText: '直接告诉 Bot 你需要什么...',
                          hintStyle: const TextStyle(fontSize: 14, color: Colors.black38),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          suffixIcon: IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: Colors.grey,
                              size: 20,
                            ),
                            onPressed: () {
                              FocusScope.of(context).unfocus();
                              if (_controller.text.trim().isEmpty) {
                                _closeInputAndWaitNav();
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Send button
                  Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _controller.text.trim().isNotEmpty || _loading
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade300,
                    ),
                    child: IconButton(
                      icon: _loading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_upward_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                      onPressed: _loading ? null : _send,
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
}

enum ChatRole { user, assistant }

class _ChatMessage {
  const _ChatMessage({
    required this.role,
    required this.content,
    this.photos = const [],
  });

  final ChatRole role;
  final String content;
  final List<BotChatPhoto> photos;
}
