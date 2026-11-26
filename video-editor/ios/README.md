# MemoirsCore 视频剪辑 iOS 模块

在 Mac 上用 Xcode 16 或更新版本打开 `VideoEditor.xcodeproj`，选择 VideoEditor scheme 和 iOS 17 或更新版本的模拟器。运行到 iPhone 时，在 Signing & Capabilities 为 VideoEditor 目标选择自己的 Team，并根据需要修改 Bundle Identifier。

## 功能验证

1. 从相册添加两段视频。可以用一段竖屏、一段横屏，也可以包含一段无声素材。
2. 拖动时间轴滑块，预览应跳到对应位置。选中片段后在片段内部点「分割」。
3. 用「前移」「后移」调整顺序，测试删除和撤销。可关闭原声。
4. 点「导出 MP4」完成后，用「分享或保存 MP4」保存文件，再重新打开检查画面朝向、剪辑顺序和声音。

## 接入 MemoirsCore

将三个 Swift 文件加入总工程的 App target，移除独立工程的 `VideoEditorApp` 入口声明，由 MemoirsCore 的导航打开 `VideoEditorView()`。临时素材和导出文件由独立编辑器会话管理。合成画幅以第一段视频为准，其他片段按比例适配。

此目录覆盖主视频轨。文字、贴纸、独立配乐、画中画、特效及草稿保存待实现。网页原型在同级 `demo/`。

