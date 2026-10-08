# 顺稿 ShunGao

<img src="Assets/ShunGao-1024.png" alt="顺稿图标" width="96">

面向 Apple Silicon Mac 的中文本地提词器。此仓库公开保存 **20261008.9** 的源码；不含可安装 App、Python 运行时或模型权重。

## 功能

- 语音跟随与定速滚动；连续柔和高亮，静音制动，镜像、全屏、字号及统一行距。
- 导入 TXT/Markdown、粘贴和编辑；移除全部空白行，段落额外间距为零，UTF-16 定位映射保持一致。
- 独立本机文稿库、自动保存、草稿恢复；右键重命名、复制、剪贴板新篇、回收站与撤销删除。
- 上次成功模型后台恢复；麦克风选择与模型加载独立，默认跟随系统，显式选择以稳定 UID 保存。
- 稿旁竖向进度与有限的语速预测；不把相邻匹配更新时间当作屏幕全链路延迟。

启动不会自动录音。主动“开始跟随”后才采集；识别在本机离线运行，模型下载是用户主动执行的独立操作。

## 本地构建

要求 macOS 15+、Apple Silicon 和 Xcode Command Line Tools。界面使用 Swift/AppKit/WKWebView，识别工作进程使用可重定位 CPython 3.10 framework 和 MLX。Intel Mac 未验证。

```sh
xcode-select --install
```

已有完整顺稿 App 时，可以复用其中的运行时：

```sh
./scripts/prepare_runtime_from_app.sh /Applications/顺稿.app
./build.sh
```

没有完整 App 时按 [运行时组装说明](docs/BUILD.md) 准备 `runtime/`。仓库没有权重或二进制；仅 `git clone` 后直接构建会明确提示运行时缺失。构建写入当前目录的 `顺稿.app`，不替换已安装 App、不修改模型或用户文稿。

生成的是 ad-hoc 开发构建，未提供 Developer ID 签名、公证或安装发行版。系统安全提示应由用户正常处理；脚本不关闭 Gatekeeper 或移除 quarantine。

## 模型

| 模型 | 固定格式 | 完整数据量 | 许可 |
| --- | --- | ---: | --- |
| SenseVoiceSmall | MLX F32 | 936,489,716 字节 | FunASR Model License 1.1 |
| Qwen3-ASR-1.7B | MLX 8bit | 2,467,857,511 字节 | Apache-2.0 |

通过应用“模型管理”下载或引用已有兼容目录。默认位于 `~/Models/MLX/`，模型存储在 App 外；文件大小与固定修订的 SHA-256 校验均通过后才允许加载。不会因缺失模型自动重下。

完整来源、修订、共用目录与许可见 [模型说明](docs/MODELS.md) 和 `model-catalog.json`。其他格式或量化版本不能直接替代此目录格式。

## 验证与使用边界

后台检查覆盖文稿库、连续轨迹、旧会话与捕获顺序拒绝、模型管理、音频调度及字符匹配。运行不打开 App、不调用真实模型的检查：

```sh
./scripts/check_source.sh
```

Python 检查使用 `PYTHON_FOR_TESTS` 指定的已准备解释器（需要依赖）。实际真人快口播、口音、噪声、硬件设备及显示舒适度仍需本机试读。数值轨迹和模型回放不等于麦克风至屏幕的完整验收。

文稿、回收站、配置和编辑草稿只写入本机 `~/Library/Application Support/顺稿/`。暂停语音时可生成仅含位置、时间和匹配指标的本机诊断，不记录正文或音频。请勿把个人状态、日志或录音上传仓库。

## 目录

- `Sources/`：原生主程序、设备枚举、模型/文稿库、阅读界面及控制器。
- `engine/`：音频处理、稳定设备映射、离线 ASR 与文稿匹配。
- `Assets/`：项目图标。
- `scripts/`：运行时组装、构建辅助与隔离检查。
- `tests/`：合成输入与隔离文件系统回归；没有真实文稿或录音。
- `dependency-lock/`：已验证依赖版本及 MLX-Audio 源修订。
- `licenses/`：原样保留的第三方许可与模型卡。

## 许可

此仓库用于公开源码存档。原创代码和图标暂未额外授予开源使用许可，见 [LICENSE](LICENSE)。第三方依赖及模型保留各自的许可，见 [第三方声明](THIRD_PARTY_NOTICES.md)；没有将其重许可为项目原创代码。标准演示文字与测试输入不包含个人文稿。
