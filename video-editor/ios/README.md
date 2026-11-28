# MemoirsCore iOS 视频剪辑

MemoirsCore 原生剪辑器支持图库照片和视频混剪、定时文字、代理预览和 MP4 导出。AI 剪辑从同一图库挑选素材，将一句话变成可编辑的时间轴。配置语音模型后，保留下来的对白会自动加字幕。

## 启动与入口

1. 在 Mac 上按[总项目说明](../../README.md)启动后端和 Flutter 客户端，使用 iOS 17 或更新版本的设备。
2. 在 App 设置中填写后端地址。模拟器可以使用 `http://127.0.0.1:8000`。iPhone 真机使用运行后端的电脑局域网地址，并允许 App 访问本地网络。
3. 在「图库」点加号导入。照片继续使用图库原有记录，视频可以在「视频」标签页查看。然后从首页设置旁打开「视频剪辑」。

也可以在 Xcode 16 或更新版本打开 `VideoEditor.xcodeproj`，选择 `VideoEditor` scheme 测试独立剪辑器。独立版从系统相册添加视频。连接项目图库和 AI 后端的功能从 MemoirsCore 主 App 进入。

## 手动剪辑

- 点「添加素材」，从图库勾选照片或视频。照片默认以 5 秒静帧插入。选中的素材按勾选顺序追加到时间轴末尾。
- 拖动时间轴滑块查看画面，在选中片段内部点「分割」，再用「前移」「后移」「删除」和「撤销」调整项目。可以添加定时文字或关闭原声。
- 开启「流畅预览」后，符合条件的高清视频会在后台生成代理。导出仍使用原始素材。
- 点「导出 MP4」，再点「分享或保存 MP4」。请在退出剪辑器前保存导出文件。图库剪辑需要连接后端，手动编辑和导出无需 AI 密钥。

## AI 剪辑与自动字幕

1. 点「AI 剪辑」，输入一句话，例如「把最近在杭州拍的剪成一段 30 秒的旅行回忆，多留家人的原声」。
2. 在「选择素材」勾选必须出现的照片或视频。开启「只用我选的素材」可以限定素材范围。没有勾选时，系统从图库自动找素材。
3. 点「生成视频」。后端读取已有标签和时间码，生成并校验剪辑清单。结果载入时间轴，可以继续调整、撤销或导出。成功导出后，可复用的剪辑偏好会在下次生成时作为参考。

导入后台会读取拍摄元数据，使用 PySceneDetect 检测镜头边界，并根据镜头内的画面变化挑选代表帧。DeepSeek 分析这些画面，已有的人物录入数据也可以提供人物线索。较早导入或还没有 AI 标签的素材，可以点「补充并刷新标签」分批更新。

启用后端语音识别后，系统会复用已缓存的转写，并自动补做入选视频缺少的转写。字幕只覆盖剪进成片的对白时间段，分割、删除或移动片段后会跟着调整。字幕显示在画面下方，并随画面导出到 MP4。语音模型缺失或部分素材识别失败时，页面会显示提示。

## 后端配置

### 先配置可以手动剪辑的后端

按[总项目的后端启动步骤](../../README.md#运行-api-后端)安装依赖、准备 MongoDB，并设置 App 的后端地址。先在手机浏览器访问 `http://后端电脑的局域网地址:8000/api/health` 确认能连通，再回 App 导入一张照片和一段视频，试着手动混剪。这个步骤无需 AI 密钥。

### 再启用 AI 一键剪辑

在**运行后端的电脑**上打开 `backend/.env`。如果文件不存在，先把 [`.env.example`](../../backend/.env.example) 复制成同目录下的 `.env`。填入自己的 DeepSeek 密钥，保存后重启后端。

```dotenv
DEEPSEEK_API_KEY=在本机填入你的密钥
```

DeepSeek 负责素材视觉标签和剪辑清单。真实密钥留在本机 `.env` 或部署环境变量中，提交给队友的配置示例只保留空值。

### 给自动字幕下载本地模型

**在运行后端的电脑完成下面三步。** `faster-whisper` 是识别程序，模型目录存放它要读取的文件。识别在后端本机运行，无需单独申请语音 API Key。

1. 激活启动后端时使用的 Python 环境。在 `backend/` 目录安装依赖并下载 [Systran 的多语言 small 模型](https://huggingface.co/Systran/faster-whisper-small)。下面命令中的 `python` 使用后端虚拟环境。若未激活环境，在 Windows 上用 `.\.venv\Scripts\python.exe`，在 macOS 上用 `.venv/bin/python` 替换。命令会把模型保存到**仓库外**。

   ```sh
   python -m pip install faster-whisper huggingface_hub
   python -c "from huggingface_hub import snapshot_download; snapshot_download('Systran/faster-whisper-small', local_dir='../../models/faster-whisper-small')"
   python -c "from pathlib import Path; p = Path('../../models/faster-whisper-small').resolve(); assert (p / 'model.bin').is_file(); print(p.as_posix())"
   ```

2. 把最后一条命令输出的**绝对目录**填入 `backend/.env`。路径示例需要换成队友自己电脑上的路径。

   ```dotenv
   # Windows 示例
   MEMOIRS_ASR_MODEL_PATH=D:/实验室/models/faster-whisper-small
   # macOS 示例，按实际路径取消注释并使用这一行
   # MEMOIRS_ASR_MODEL_PATH=/Users/你的用户名/models/faster-whisper-small
   ```

3. 重启后端。在 App 导入一段有清晰对白的短视频，打开「AI 剪辑」，勾选它并开启「只用我选的素材」，再点「生成视频」。预览画面下方应显示对白字幕。导出 MP4 并重新打开，确认字幕和原声同步。

如果页面提示「后端尚未配置语音识别」，检查 `.env` 是否保存并重启了后端。如果提示部分素材识别失败，核对模型目录里是否有 `model.bin`、后端实际使用的 Python 能否导入 `faster_whisper`，以及入选片段是否有清晰对白。首次处理尚未转写的视频可能需要一些时间。

### 按需启用 Seedance

只在需要生成过渡画面时配置 `ARK_API_KEY` 和 `MEMOIRS_SEEDANCE_MODEL`。重启后端后，在 AI 剪辑页打开「允许 AI 补过渡画面」。补入的画面会标注「AI 生成画面」。

## 联调检查

| 场景 | 检查内容 |
| --- | --- |
| 手动混剪 | 用一张照片、一段横屏有声视频和一段竖屏视频，检查顺序、画幅、原声和导出文件。 |
| AI 必用素材 | 勾选两项素材，确认时间轴包含两项。开启「只用我选的素材」后，确认时间轴只使用勾选项。 |
| 自动字幕 | 用有对白和无声的素材生成一条片，检查字幕与原声同步、无声片段没有对白字幕。分割并移动有声片段后，再检查预览及重新打开的 MP4。 |
| 代理预览 | 用高分辨率素材比较开启前后的预览，确认导出文件仍由原素材合成。 |

Runner 直接引用本目录的 Swift 文件，通过 `MEMOIRSCORE_HOST` 使用 Flutter 的 App 入口。网页原型见[浏览器 Demo](../demo/README.md)。
