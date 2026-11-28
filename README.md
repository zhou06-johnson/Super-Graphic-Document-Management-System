# MemoirsCore iOS 适配项目

这是基于原始源码整理的 iOS 客户端及其 API 后端。Flutter 客户端可在后端
未启动时打开；连接后端后，照片、回忆、故事、行程和 Bot 才能使用。首页
会在本机缓存最近一次卡片元数据和 API 地址。

## 运行 iOS 客户端

需要 macOS、Xcode、CocoaPods 和符合 [Flutter 项目 SDK 约束](mobile/pubspec.yaml) 的 Flutter 环境。Runner 的部署目标为 iOS 17。启动模拟器后，在仓库目录运行：

```sh
cd mobile
flutter pub get
flutter devices
flutter run
```

在 Windows 上可以直接用浏览器打开[剪辑 Demo](video-editor/demo/index.html)。测试原生剪辑和 MP4 导出时使用 iOS 模拟器或 iPhone。

## 视频剪辑

在 MemoirsCore 的「图库」中导入照片和视频，再从首页打开「视频剪辑」。「添加素材」用于手动混剪，「AI 剪辑」用于根据一句话和必用素材生成可编辑的时间轴。启用本地语音识别后，AI 剪辑会为留下的对白自动加字幕，预览和导出都可查看。

- 先按下方步骤运行后端，再按[剪辑联调指南](video-editor/ios/README.md#后端配置)依次验证手动剪辑、配置 DeepSeek、下载本地语音模型和测试自动字幕。
- [网页 Demo 说明](video-editor/demo/README.md)涵盖浏览器演示和项目结构。

## 运行 API 后端

运行后端的电脑需要 Python 和 MongoDB。先启动 MongoDB，再从仓库根目录进入 `backend/` 并安装依赖。

**Windows PowerShell**

```powershell
Set-Location backend
python -m venv .venv
if (-not (Test-Path -LiteralPath .env)) { Copy-Item .env.example .env }
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe main.py
```

**macOS**

```sh
cd backend
brew install cmake dlib imagemagick
python3 -m venv .venv
test -f .env || cp .env.example .env
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python main.py
```

启动后打开 `http://127.0.0.1:8000/api/health`。iOS 模拟器与后端在同一台 Mac 时，App 可填 `http://127.0.0.1:8000`。真机或另一台电脑访问时，后端在 `.env` 里配置 `MEMOIRS_HOST=0.0.0.0`，App 填实际局域网地址，例如 `http://192.168.1.20:8000`。两台设备应能互相访问，电脑防火墙需允许局域网连接 8000 端口。

地图、Bot 和 AI 剪辑使用各自的后端配置。请在本机的 `backend/.env` 填真实密钥，提交给队友的 `.env.example` 只保留占位项。配置改动后重启后端。

## 本地存储

Flutter 客户端通过 `path_provider` 将少量 JSON 保存到系统 Application
Support 目录，记录 API 地址和首页最近一次成功读取的卡片数据。缓存不含
照片本身，也不替代后端数据库；清除应用数据或卸载应用会清掉本机缓存。

## iOS 构建说明

- `mobile/ios/Podfile` 管理 iOS 插件依赖。
- `mobile/ios/Runner/Info.plist` 声明位置、相册和局域网用途，并允许 ATS 本地网络
  连接。真机首次联网时需在系统提示中允许本地网络访问。
- 真机签名时，在 Xcode 中为 Runner 选择 Apple 开发团队，并按需更改 Bundle Identifier。

## 文件说明

见 [`FILE_GUIDE.md`](FILE_GUIDE.md)，其中列出了本交付项目内各源码、配置、
测试和资源文件的用途。
