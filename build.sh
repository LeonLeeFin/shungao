#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="${SHUNGAO_BUILD_APP:-$PWD/顺稿.app}"
if [[ ! -d runtime && ! -d "$APP/Contents/Resources/runtime" ]]; then
  print -u2 "缺少独立运行时：请先从完整迁移包保留 App，或按构建说明组装 runtime。"
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
swiftc -target arm64-apple-macos14.0 Sources/*.swift -o build/ShunGao -O -framework AppKit -framework WebKit -framework AVFoundation -framework CoreAudio -framework UniformTypeIdentifiers -module-cache-path "$PWD/build/module-cache"
cp build/ShunGao "$APP/Contents/MacOS/ShunGao"
cp model-catalog.json "$APP/Contents/Resources/model-catalog.json"
cp Sources/ui.html "$APP/Contents/Resources/ui.html"
cp Sources/*.js "$APP/Contents/Resources/"
cp Assets/ShunGao.icns "$APP/Contents/Resources/ShunGao.icns"
mkdir -p "$APP/Contents/Resources/engine"
cp engine/*.py "$APP/Contents/Resources/engine/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ShunGao</string>
<key>CFBundleIdentifier</key><string>local.leon.shungao.recovery</string>
<key>CFBundleName</key><string>顺稿</string>
<key>CFBundleDisplayName</key><string>顺稿</string>
<key>CFBundleIconFile</key><string>ShunGao</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>20261008.9</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>顺稿使用麦克风在本机离线识别你的朗读，定位文稿并滚动。音频不上传，也不保存原始录音。</string>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>local.leon.shungao.recovery.document</string><key>UTTypeConformsTo</key><array><string>public.json</string></array><key>UTTypeDescription</key><string>顺稿文稿</string><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>sgprompt</string></array></dict></dict></array>
</dict></plist>
PLIST
if [[ -d runtime ]]; then
  mkdir -p "$APP/Contents/Resources/runtime"
  rsync -a --delete runtime/ "$APP/Contents/Resources/runtime/"
fi
mkdir -p "$APP/Contents/Resources/licenses"
cp licenses/* "$APP/Contents/Resources/licenses/"
codesign --force --sign - "$APP"
shasum -a 256 "$APP/Contents/MacOS/ShunGao" > build/SHA256.txt
print "已构建：$APP"
