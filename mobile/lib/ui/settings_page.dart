import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/local_app_store.dart';

/// iOS-style settings screen for choosing the computer that runs the API.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _urlController = TextEditingController();
  bool _didLoad = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoad) return;
    _urlController.text = context.read<ApiClient>().baseUrl;
    _didLoad = true;
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _urlController.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = '请输入完整地址，例如 http://192.168.1.20:8000');
      return;
    }

    try {
      await context.read<LocalAppStore>().saveApiBaseUrl(value);
      if (!mounted) return;
      context.read<ApiClient>().updateBaseUrl(value);
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('设置'),
        previousPageTitle: 'MemoirsCore',
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _save,
          child: const Text('保存'),
        ),
      ),
      child: SafeArea(
        bottom: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                '服务器连接',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel,
                  fontSize: 13,
                ),
              ),
            ),
            CupertinoFormSection.insetGrouped(
              children: [
                CupertinoFormRow(
                  prefix: const Text('API 地址'),
                  child: CupertinoTextField(
                    controller: _urlController,
                    placeholder: 'http://192.168.1.20:8000',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => _save(),
                    decoration: null,
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _error!,
                  style: const TextStyle(color: CupertinoColors.systemRed),
                ),
              ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'iOS 模拟器可填 http://127.0.0.1:8000。iPhone 真机请填运行后端电脑的局域网 IP 地址；电脑和手机需要连接同一 Wi-Fi。后端需监听 0.0.0.0:8000。',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
