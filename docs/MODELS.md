# 模型来源与下载

项目只公开模型目录说明和校验目录，不分发权重。应用管理器只在用户点击后下载固定数据文件，经大小和 SHA-256 校验后原子提交；取消/失败保留续传片段。亦可引用已有兼容目录，不复制或移动原权重。

| 模型来源 | 固定修订 | 默认路径 |
| --- | --- | --- |
| [mlx-community/SenseVoiceSmall](https://huggingface.co/mlx-community/SenseVoiceSmall) | `8ddd966bd96243cff196422f81f0c5d955814792` | `~/Models/MLX/SenseVoiceSmall/F32/8ddd966bd96243cff196422f81f0c5d955814792` |
| [mlx-community/Qwen3-ASR-1.7B-8bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit) | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | `~/Models/MLX/Qwen3-ASR-1.7B/8bit/a8379a2e2f9e313c9292cdf1af4055ab56d50d55` |

上游项目为 [SenseVoice](https://github.com/FunAudioLLM/SenseVoice) / [FunASR](https://github.com/modelscope/FunASR) 和 [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)。MLX 转换数据由上述 mlx-community 仓库提供，顺稿不冒称原模型作者。

SenseVoice 模型数据使用 [FunASR Model License 1.1](../licenses/FunASR-MODEL_LICENSE.txt)，Qwen 使用 [Apache-2.0](../licenses/Qwen3-ASR-Apache-2.0.txt)。下载和使用前须阅读上游许可；模型许可与应用原创代码权利分开。没有把权重或模型许可改为项目自己的许可证。

`model-catalog.json` 包含实际固定修订文件名、大小、SHA-256 与dtype/量化格式。请使用匹配的数据格式；PyTorch、其他量化配置及不完整目录不会被当作兼容的 MLX 权重加载。
