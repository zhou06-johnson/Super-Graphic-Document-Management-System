# MemoirsCore 视频剪辑 iOS 模块

在 Mac 上用 Xcode 16 或更新版本打开 `VideoEditor.xcodeproj`，选择 VideoEditor scheme 和 iOS 17 或更新版本的模拟器。运行到 iPhone 时，在 Signing & Capabilities 为 VideoEditor 目标选择自己的 Team，并根据需要修改 Bundle Identifier。

## 功能验证

1. 从相册添加两段视频。可以用一段竖屏、一段横屏，也可以包含一段无声素材。
2. 拖动时间轴滑块，预览应跳到对应位置。选中片段后在片段内部点「分割」。
3. 用「前移」「后移」调整顺序，测试删除和撤销。可关闭原声。
4. 点「导出 MP4」完成后，用「分享或保存 MP4」保存文件，再重新打开检查画面朝向、剪辑顺序和声音。

## 接入 MemoirsCore

在 Mac 上进入总仓库的 `mobile/`，执行 `flutter pub get` 和 `flutter run`，选择 iOS 17 或更新版本的设备。打开 MemoirsCore 后，点首页右上方、设置旁的「视频剪辑」。用上面的步骤验证导入、剪辑和导出，再点「返回」确认可以回到首页。

Runner 直接引用此目录的三个 Swift 文件，并通过 `MEMOIRSCORE_HOST` 编译条件使用 Flutter 的 App 入口。独立 Xcode 工程仍可单独运行。临时素材和导出文件由本次编辑会话管理。导出后请先保存或分享，再退出剪辑页。

原生端提供主视频轨、定时文字和流畅预览。网页原型在同级 `demo/`。

## 图库剪辑与 AI 剪辑联调

主 App 的「添加素材」和「AI 剪辑」使用同一个图库。手动勾选的照片默认以 5 秒静帧加入时间轴，可与视频一起分割、删除、调整顺序和导出。手动添加和导出无需 AI 密钥。

1. 在总项目后端安装 `requirements.txt`，在 `backend/.env` 设置 `DEEPSEEK_API_KEY`，重启后端。iPhone 的 MemoirsCore 设置使用该后端地址。
2. 从 MemoirsCore 的「图库」点加号导入照片或视频。照片继续使用原图库记录，视频在「视频」标签页查看。后台读取元数据，用 PySceneDetect 和镜头内变化筛选代表帧，再用 DeepSeek 打标签。较早的照片可从 AI 剪辑点「补充并刷新标签」。
3. 等待标签刷新后，在「选择素材」勾选必用项，输入剪辑要求。生成结果载入可撤销的时间轴，随后可手改或导出 MP4。导出成功后记录可复用的剪辑偏好，供后续生成参考。

视频可复用现有录入的人脸特征。需要语音时间码时，在后端另行安装 `faster-whisper`，将 `MEMOIRS_ASR_MODEL_PATH` 指向已有的本地模型目录。需要补镜头时，填写 `ARK_API_KEY` 和 `MEMOIRS_SEEDANCE_MODEL`，再在 AI 剪辑里打开「允许 AI 补过渡画面」。生成镜头会标注「AI 生成画面」。

将 `backend/.env.example` 复制成同目录下的 `backend/.env` 并在本机填写密钥。仓库忽略 `.env`，示例文件只保留空值。该入口依赖 MemoirsCore 主 App 传入的后端地址。独立 Xcode 工程支持手动剪辑。
