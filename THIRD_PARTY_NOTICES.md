# 第三方声明

本次公开包没有捆绑第三方运行时二进制、Python 包源码或模型权重。依赖与模型在本机另行准备，适用各自许可；根目录LICENSE仅描述项目原创文件，不改变以下版权与许可。

| 项目 | 使用方式 / 来源 | 保留许可 |
| --- | --- | --- |
| MLX-Audio | 本机依赖；固定源修订 `364585faa92dbff819583e0e5bf691e256179590`，https://github.com/Blaizzy/mlx-audio | MIT，Copyright (c) 2024 Prince Canuma，见 `licenses/mlx-audio-MIT.txt` |
| Qwen3-ASR | 本机外置模型，上游 Alibaba Cloud，https://github.com/QwenLM/Qwen3-ASR | Apache-2.0，见 `licenses/Qwen3-ASR-Apache-2.0.txt` 与模型卡 |
| SenseVoice / FunASR | 本机外置模型，上游 Alibaba Group / FunAudioLLM，https://github.com/FunAudioLLM/SenseVoice | FunASR Model License 1.1，见 `licenses/FunASR-MODEL_LICENSE.txt` 与模型卡 |
| CPython | 开发者组装的本机 framework，https://www.python.org | 适用其 PSF License 及随附声明；本仓库不分发该运行时 |
| MLX、NumPy、SciPy、sounddevice、soundfile、pypinyin 等 | `dependency-lock/requirements-runtime.lock` 列出的另行安装依赖 | 适用各发行包附带许可；不能从本项目根LICENSE推导其授权 |

许可证文件与固定模型卡从项目已验证快照原样保留。组装脚本保留复制依赖的许可目录；发布包含这些依赖的可安装App需另行完整审核全部实际捆绑内容。本次只公开顺稿源码，既没有模型重分发，也没有替第三方授予新的许可。

`Assets/ShunGao-1024.png` 和 `ShunGao.icns` 是本项目用户确认的生成式图标，用于本项目标识，不冒称第三方商标。
