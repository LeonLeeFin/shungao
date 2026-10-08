# 运行时组装

公开包排除了所有编译产物、Python/MLX 运行时和权重。`build.sh` 保持 .9 的 framework 布局；不要直接把虚拟环境目录改名为 `runtime`。

## 复用完整 App

`./scripts/prepare_runtime_from_app.sh /Applications/顺稿.app` 验证现有 App 签名，然后仅复制嵌入运行时到此源码目录。该方式已在项目开发中验证；不会更改现有 App 或外置模型。

## 从本机依赖组装

这是供开发者使用的组装路径；需要可用的 arm64 CPython **3.10 framework**、PortAudio/libsndfile 等本机依赖和开发工具。锁定版本对应项目已验证环境，公共网络当前是否仍提供全部 wheel 未在发布时重新安装验证。

示例（Homebrew 安装路径仅为可替换的通用示例）：

```sh
brew install python@3.10 portaudio libsndfile
framework="$(brew --prefix python@3.10)/Frameworks/Python.framework"
"$framework/Versions/3.10/bin/python3.10" -m venv .venv-runtime
.venv-runtime/bin/python -m pip install -r dependency-lock/requirements-runtime.lock
mkdir -p .build-tools
git clone https://github.com/Blaizzy/mlx-audio .build-tools/mlx-audio
git -C .build-tools/mlx-audio checkout --detach 364585faa92dbff819583e0e5bf691e256179590
python3 scripts/bundle_runtime.py   --python-framework "$framework"   --site-packages "$PWD/.venv-runtime/lib/python3.10/site-packages"   --mlx-source "$PWD/.build-tools/mlx-audio"   --destination "$PWD/runtime"
python3 scripts/audit_runtime.py runtime
./build.sh
```

组装器复制明确提供的本机 framework/包、修正拷贝内的动态库引用、保留包许可并 ad-hoc 签名，不下载模型或加载 MLX 模型。Mach-O 修复只作用于复制后的二进制元数据，不改系统加载器或安全设置。若依赖、framework 或签名审核失败，应修复组装环境，不忽略错误。

发布二进制之前需另行审核每个实际捆绑依赖的许可，并准备 Developer ID 签名/公证。本仓库本次只发布源码，不提供二进制分发。

## 检查

```sh
PYTHON_FOR_TESTS=.venv-runtime/bin/python ./scripts/check_source.sh
```

检查运行隔离文稿库、JavaScriptCore 数值轨迹以及 Python 模拟音频/匹配回归，不打开已安装 App，不录音或调用真实模型。
