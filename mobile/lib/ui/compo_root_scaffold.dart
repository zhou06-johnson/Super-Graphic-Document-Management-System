import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bot/bot_chat_page.dart';
import 'chat_ui_state.dart';
import 'home/home_page.dart';
import 'library/library_page.dart';

/// 与首页 [home_page.dart] 中 `_kGlassBackdropBlur`（18）一致。
const double _kNavGlassBlur = 18.0;

class CompoRootScaffold extends StatefulWidget {
  const CompoRootScaffold({super.key});

  @override
  State<CompoRootScaffold> createState() => _CompoRootScaffoldState();
}

class _CompoRootScaffoldState extends State<CompoRootScaffold> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    HomePage(),
    LibraryPage(),
    BotChatPage(),
  ];

  void _onTabSelected(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hideNav = context.select<ChatUiState, bool>((s) => s.isBotInputExpanded) && _currentIndex == 2;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          IndexedStack(
            index: _currentIndex,
            children: _pages,
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            left: 0,
            right: 0,
            bottom: hideNav ? -140 : 32,
            child: IgnorePointer(
              ignoring: hideNav,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: hideNav ? 0 : 1,
                child: _CompoRootGlassNavBar(
                  currentIndex: _currentIndex,
                  onChanged: _onTabSelected,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompoRootGlassNavBar extends StatelessWidget {
  const _CompoRootGlassNavBar({
    required this.currentIndex,
    required this.onChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = const [
      _NavItem(icon: CupertinoIcons.house_fill, label: '首页'),
      _NavItem(icon: CupertinoIcons.photo_on_rectangle, label: '图库'),
      _NavItem(icon: CupertinoIcons.chat_bubble_2_fill, label: '助手'),
    ];

    return SafeArea(
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: _kNavGlassBlur,
              sigmaY: _kNavGlassBlur,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F8).withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(items.length, (index) {
                  final selected = index == currentIndex;
                  final item = items[index];

                  final color = selected
                      ? const Color(0xFF007AFF)
                      : const Color(0xFF777A80);
                  return Semantics(
                    button: true,
                    selected: selected,
                    label: item.label,
                    child: GestureDetector(
                      onTap: () => onChanged(index),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 72,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF007AFF).withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(item.icon, color: color, size: 21),
                            const SizedBox(height: 2),
                            Text(
                              item.label,
                              style: TextStyle(
                                color: color,
                                fontSize: 10,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.label,
  });
}
