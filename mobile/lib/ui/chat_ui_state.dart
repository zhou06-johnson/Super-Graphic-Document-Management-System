import 'package:flutter/foundation.dart';

/// Global UI state shared across pages.
/// Currently used to hide/show bottom navigation when Bot input expands.
class ChatUiState extends ChangeNotifier {
  bool _isBotInputExpanded = false;

  bool get isBotInputExpanded => _isBotInputExpanded;

  void setBotInputExpanded(bool value) {
    if (_isBotInputExpanded == value) return;
    _isBotInputExpanded = value;
    notifyListeners();
  }
}

