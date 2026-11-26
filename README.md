# MemoirsCore iOS 适配项目

这是基于原始源码整理的 iOS 客户端及其 API 后端。Flutter 客户端可在后端
未启动时打开；连接后端后，照片、回忆、故事、行程和 Bot 才能使用。首页
会在本机缓存最近一次卡片元数据和 API 地址。

## iOS 模拟器

在 macOS 上也可以从项目根目录一键启动：

```sh
chmod +x start.sh   # 仅首次需要
./start.sh
```

脚本会准备 Python 虚拟环境与 Flutter/iOS 依赖，启动 API，然后运行 Flutter
应用。首次安装后再次运行会复用本地依赖。支持 `./start.sh mobile` 只运行应用、
`./start.sh backend` 只运行后端。运行前需安装 Xcode、Flutter、CocoaPods 和
Python 3；后端功能还需启动 MongoDB。脚本会在首次启动时从示例文件创建
`backend/.env`，地图及 Bot 功能所需密钥需自行填写。按 Ctrl+C 会停止脚本启动
的进程。

需要 macOS、Xcode、Flutter（满足 `mobile/pubspec.yaml` 的 Dart SDK 约束）和
CocoaPods。打开终端运行：

```sh
cd mobile
flutter doctor
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```

在 Xcode 选择 iPhone 模拟器并运行；也可以用 `flutter devices` 查看设备后
执行 `flutter run -d <device-id>`。首次 `flutter pub get` 会重建被原压缩包
污染的机器专属配置。不要从旧 Windows 构建目录复制生成文件回来。

## 运行 API 后端

后端需要 Python 依赖、MongoDB 服务；地图和 Bot 功能还需要相应 API 密钥。
从 `backend/` 目录运行：

```sh
brew install cmake dlib imagemagick
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

先启动 MongoDB，并在 `.env` 中填写需要的密钥。iPhone 真机访问时，后端
需要监听局域网接口：

```sh
MEMOIRS_HOST=0.0.0.0 MEMOIRS_PORT=8000 python main.py
```

在 iOS 设置页输入运行后端的电脑局域网地址，例如
`http://192.168.1.20:8000`。模拟器的默认地址为
`http://127.0.0.1:8000`。电脑防火墙需允许本地网络的 8000 端口访问。

`backend/.env` 不随本项目交付；请从 `.env.example` 创建，并自行填写密钥。
不要将真实密钥提交到版本库或分享的压缩包。

## 本地存储

Flutter 客户端通过 `path_provider` 将少量 JSON 保存到系统 Application
Support 目录，记录 API 地址和首页最近一次成功读取的卡片数据。缓存不含
照片本身，也不替代后端数据库；清除应用数据或卸载应用会清掉本机缓存。

## iOS 构建说明

- iOS 部署目标为 13.0；`ios/Podfile` 安装插件 CocoaPods。
- `ios/Runner/Info.plist` 声明位置、相册和局域网用途，并允许 ATS 本地网络
  连接。真机首次联网时需在系统提示中允许本地网络访问。
- Xcode 工程初始 Bundle Identifier 是 `com.example.mobile`。真机签名或
  发布前，请在 Xcode 换成你自己的唯一标识并选择 Apple 开发团队。
- 当前执行环境没有 Flutter、Dart 或 CocoaPods，且 iOS 模拟器服务不可用；
  因此本次无法在此环境完成 Flutter 编译或真机/模拟器启动。源码与配置检查
  结果列在交付说明中。

## 文件说明

见 [`FILE_GUIDE.md`](FILE_GUIDE.md)，其中列出了本交付项目内各源码、配置、
测试和资源文件的用途。
