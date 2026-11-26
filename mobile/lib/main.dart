import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'services/api_client.dart';
import 'services/local_app_store.dart';
import 'ui/compo_root_scaffold.dart';
import 'ui/chat_ui_state.dart';

const String kDefaultApiBaseUrl = 'http://127.0.0.1:8000';
const String _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

String _defaultApiUrl() {
  if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
  if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb) {
    return 'http://10.0.2.2:8000';
  }
  return kDefaultApiBaseUrl;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  final localStore = LocalAppStore();
  String apiBaseUrl = _defaultApiUrl();

  if (!kIsWeb) {
    try {
      await localStore.initialize().timeout(const Duration(seconds: 3));
      apiBaseUrl = await localStore.readApiBaseUrl().timeout(
            const Duration(seconds: 2),
          ) ??
          apiBaseUrl;
    } catch (error) {
      debugPrint('Local settings unavailable; starting with defaults: $error');
    }

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  runApp(MemoirsCoreApp(localStore: localStore, apiBaseUrl: apiBaseUrl));
}

class MemoirsCoreApp extends StatelessWidget {
  const MemoirsCoreApp({
    super.key,
    this.localStore,
    this.apiBaseUrl = kDefaultApiBaseUrl,
  });

  final LocalAppStore? localStore;
  final String apiBaseUrl;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>(
          create: (_) => ApiClient(baseUrl: apiBaseUrl),
        ),
        Provider<LocalAppStore>(
          create: (_) => localStore ?? LocalAppStore(),
        ),
        ChangeNotifierProvider<ChatUiState>(
          create: (_) => ChatUiState(),
        ),
      ],
      child: MaterialApp(
        title: 'MemoirsCore',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          platform: defaultTargetPlatform,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF007AFF),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          // 🚨 核心修复：强制使用系统内置字体，阻止去 Google 下载
          fontFamily: 'sans-serif',
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            },
          ),
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            // 强制覆盖 AppBar 的默认字体
            titleTextStyle: TextStyle(
              fontFamily: 'sans-serif',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          scaffoldBackgroundColor: Colors.transparent,
        ),
        // 🚨 核心修复：全局包裹文字样式，拦截所有组件（包括底部导航栏）的字体请求
        builder: (context, child) {
          return DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'sans-serif',
              color: Colors.black87,
            ),
            child: child!,
          );
        },
        home: const CompoRootScaffold(),
      ),
    );
  }
}