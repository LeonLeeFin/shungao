#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="${1:-/Applications/顺稿.app}"
source_runtime="$source_app/Contents/Resources/runtime"
[[ -d "$source_runtime/Python.framework" ]] || { print -u2 '找不到完整顺稿 App 内的独立运行时。'; exit 1; }
codesign --verify --deep --strict "$source_app"
mkdir -p runtime
rsync -a --delete "$source_runtime/" runtime/
print '已从完整 App 复制已签名运行时到源码目录。未修改安装的 App 或任何模型。'
