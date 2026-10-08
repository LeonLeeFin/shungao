#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./build.sh
runtime_root="$PWD/顺稿.app/Contents/Resources/runtime/Python.framework/Versions/3.10"
runtime_python="$runtime_root/Resources/Python.app/Contents/MacOS/Python"
env PYTHONHOME="$runtime_root" PYTHONNOUSERSITE=1 "$runtime_python" -B -s -m unittest discover -s tests -p 'test_*.py' -v
swiftc -parse-as-library Sources/model_manager.swift tests/model_manager_tests.swift -o build/model-manager-tests -framework Foundation -framework CryptoKit -module-cache-path "$PWD/build/module-cache"
fixture_dir="$(mktemp -d "$PWD/tests/model-manager-run.XXXXXX")"
./build/model-manager-tests "$fixture_dir"
./顺稿.app/Contents/MacOS/ShunGao --ui-test
./顺稿.app/Contents/MacOS/ShunGao --motion-test
codesign --verify --deep --strict 顺稿.app
print '完成非模型检查；未执行真实模型、下载权重或录音。'
