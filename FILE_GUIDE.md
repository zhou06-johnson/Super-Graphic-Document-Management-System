# 文件用途索引

以下逐项说明本交付项目内的源码、配置、测试和图片资源。Flutter、CocoaPods 与 Xcode 构建缓存不包含在内；它们会在 Mac 上重新生成。

| 文件 | 作用 |
|---|---|
| `README.md` | 项目总体说明：iOS 启动、后端连接、本地缓存和构建限制。 |
| `backend/.env.example` | 环境变量模板；复制为 .env 后填写密钥、MongoDB 和监听配置。 |
| `backend/enrollment_logic.py` | 人物/人脸样本录入、编码更新和相关图片处理。 |
| `backend/exceptions.py` | 后端业务自定义异常。 |
| `backend/main.py` | FastAPI 后端入口；初始化服务并提供照片、回忆、故事、行程、地图和 Bot API。 |
| `backend/memoir_feed.py` | 回忆流 API 路由、响应结构和演示数据。 |
| `backend/migrate_sqlite_to_mongo.py` | 旧 SQLite 元数据迁移到 MongoDB 的维护脚本。 |
| `backend/mongo_bootstrap.py` | 创建 MongoDB 集合、校验规则和索引的初始化脚本。 |
| `backend/mongo_enhanced.py` | MongoDB 图片元数据、人物、地点和卡片数据读写帮助函数。 |
| `backend/organizer_logic.py` | 照片扫描、元数据读取、整理和人脸处理业务逻辑。 |
| `backend/requirements.mongo.txt` | MongoDB 相关的精简可选依赖清单。 |
| `backend/requirements.txt` | 后端 Python 依赖清单。 |
| `mobile/.gitignore` | Flutter 工程 Git 忽略规则。 |
| `mobile/.metadata` | Flutter 工程版本和平台迁移元数据。 |
| `mobile/README.md` | Flutter/iOS 启动、API 地址及设备连接说明。 |
| `mobile/analysis_options.yaml` | Dart 静态分析规则。 |
| `mobile/ios/.gitignore` | 忽略 iOS Pods、Xcode 构建和 Flutter 生成文件。 |
| `mobile/ios/Flutter/AppFrameworkInfo.plist` | Flutter 引擎 Framework 包元信息。 |
| `mobile/ios/Flutter/Debug.xcconfig` | iOS Debug 构建配置并引入 Flutter 生成设置。 |
| `mobile/ios/Flutter/Release.xcconfig` | iOS Release 构建配置并引入 Flutter 生成设置。 |
| `mobile/ios/Podfile` | CocoaPods 集成 Flutter iOS 插件并设置最低部署版本。 |
| `mobile/ios/Runner.xcodeproj/project.pbxproj` | Xcode Runner 工程的构建目标、资源、签名和部署设置。 |
| `mobile/ios/Runner.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | Xcode 工程内部 workspace 描述。 |
| `mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | Xcode workspace 的检查/编辑器工作区设置。 |
| `mobile/ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | Xcode workspace 的检查/编辑器工作区设置。 |
| `mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` | Xcode Runner 构建、运行、测试和归档方案。 |
| `mobile/ios/Runner.xcworkspace/contents.xcworkspacedata` | Xcode workspace 文件，引用 Runner 项目。 |
| `mobile/ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist` | Xcode workspace 的检查/编辑器工作区设置。 |
| `mobile/ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings` | Xcode workspace 的检查/编辑器工作区设置。 |
| `mobile/ios/Runner/AppDelegate.swift` | iOS 原生启动入口并注册 Flutter 插件。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json` | App Icon 资源清单。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png` | iOS 应用图标图片资源（1024x1024@1x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png` | iOS 应用图标图片资源（20x20@1x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png` | iOS 应用图标图片资源（20x20@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png` | iOS 应用图标图片资源（20x20@3x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png` | iOS 应用图标图片资源（29x29@1x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png` | iOS 应用图标图片资源（29x29@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png` | iOS 应用图标图片资源（29x29@3x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png` | iOS 应用图标图片资源（40x40@1x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png` | iOS 应用图标图片资源（40x40@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png` | iOS 应用图标图片资源（40x40@3x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png` | iOS 应用图标图片资源（60x60@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png` | iOS 应用图标图片资源（60x60@3x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png` | iOS 应用图标图片资源（76x76@1x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png` | iOS 应用图标图片资源（76x76@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png` | iOS 应用图标图片资源（83.5x83.5@2x 槽位）。 |
| `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/Contents.json` | Launch Image 资源清单。 |
| `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png` | iOS 启动画面图片资源（LaunchImage.png 分辨率变体）。 |
| `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png` | iOS 启动画面图片资源（LaunchImage@2x.png 分辨率变体）。 |
| `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png` | iOS 启动画面图片资源（LaunchImage@3x.png 分辨率变体）。 |
| `mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/README.md` | Launch Image 资源组说明。 |
| `mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard` | iOS 启动屏幕布局。 |
| `mobile/ios/Runner/Base.lproj/Main.storyboard` | iOS 原生主 Storyboard 容器。 |
| `mobile/ios/Runner/Info.plist` | iOS App 元数据和受保护资源用途说明。 |
| `mobile/ios/Runner/Runner-Bridging-Header.h` | Swift 与 Objective-C 插件注册头桥接。 |
| `mobile/ios/RunnerTests/RunnerTests.swift` | Xcode Runner 原生测试 target 占位文件。 |
| `mobile/lib/main.dart` | Flutter 入口；初始化本地存储、平台 API 默认地址、全局 Provider 和 iOS 路由主题。 |
| `mobile/lib/models/check_in_preview_point.dart` | 行程地图预览用的打卡点模型及 JSON 转换。 |
| `mobile/lib/models/location_card.dart` | 行程卡片数据模型及后端 JSON 转换。 |
| `mobile/lib/models/memoir_feed.dart` | 回忆流照片、文字、视频多态数据模型。 |
| `mobile/lib/models/story_card.dart` | 故事卡片模型及后端 JSON 转换。 |
| `mobile/lib/services/api_client.dart` | 封装 FastAPI 的 JSON、照片上传、地图、Bot、回忆/故事/行程 API，并支持运行时更换服务器地址。 |
| `mobile/lib/services/local_app_store.dart` | 将 API 地址和首页最近一次卡片 JSON 持久化到系统 Application Support 目录。 |
| `mobile/lib/services/memoir_feed_api_service.dart` | 获取并解析 /api/v1/memoirs/feed 回忆流。 |
| `mobile/lib/ui/bot/bot_chat_page.dart` | Bot 对话页面、消息列表、输入面板及后端请求。 |
| `mobile/lib/ui/chat_ui_state.dart` | 共享助手输入面板展开状态。 |
| `mobile/lib/ui/compo_root_scaffold.dart` | 应用根页面；管理首页、图库、助手三个标签及 iOS 风格底部导航。 |
| `mobile/lib/ui/compo_wave_background.dart` | 绘制循环动画波浪背景。 |
| `mobile/lib/ui/home/add_location_card_page.dart` | 新建行程及打卡点；含地图选点、定位、图片上传。 |
| `mobile/lib/ui/home/add_memory_card_page.dart` | 新建回忆卡片的编辑、选图和上传界面。 |
| `mobile/lib/ui/home/add_story_card_page.dart` | 新建图文故事的块编辑、选图和发布界面。 |
| `mobile/lib/ui/home/home_page.dart` | 首页卡片瀑布流；读取网络数据/本地缓存、删除卡片、进入新增与设置流程。 |
| `mobile/lib/ui/home/photo_enhanced_editor_dialog.dart` | 照片人物、时间、地点和说明元数据编辑对话框。 |
| `mobile/lib/ui/home/preview_location_card_page.dart` | 行程详情和地图预览。 |
| `mobile/lib/ui/home/preview_memory_card_page.dart` | 回忆卡片详情预览。 |
| `mobile/lib/ui/home/preview_story_card_page.dart` | 故事详情预览。 |
| `mobile/lib/ui/library/all_photos_view.dart` | 图库照片网格、排序、选择和照片详情/编辑交互。 |
| `mobile/lib/ui/library/library_page.dart` | 图库入口；按时间/地点/人物展示照片，并从系统相册选择上传照片。 |
| `mobile/lib/ui/library/library_sort_mode.dart` | 图库排序/分类模式定义。 |
| `mobile/lib/ui/settings_page.dart` | iOS 风格服务器设置页；编辑并持久保存 API 地址。 |
| `mobile/pubspec.lock` | 锁定解析后的 Flutter/Dart 依赖版本。 |
| `mobile/pubspec.yaml` | Flutter 包元数据、Dart 版本约束、插件依赖和资源配置。 |
| `mobile/test/widget_test.dart` | Flutter 应用根组件的 widget 冒烟测试。 |
