#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
ADB_BINARY="${ADB_BINARY:-$HOME/Library/Android/sdk/platform-tools/adb}"
if [ ! -x "$ADB_BINARY" ]; then
  ADB_BINARY="$(command -v adb || true)"
fi
if [ ! -x "$ADB_BINARY" ]; then
  echo "未找到 ADB。请安装 platform-tools 或通过 ADB_BINARY 指定路径。" >&2
  exit 1
fi
swift build -c release --arch "$BUILD_ARCH" --disable-sandbox --scratch-path .build \
  -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache"
BIN_DIR="$(swift build -c release --arch "$BUILD_ARCH" --disable-sandbox --scratch-path .build --show-bin-path)"
APP="$PROJECT_ROOT/dist/APK Exporter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_ROOT/.build/AppIcon.iconset"
cp "$BIN_DIR/APKExporter" "$APP/Contents/MacOS/APKExporter"
cp "$ADB_BINARY" "$APP/Contents/Resources/adb"
chmod +x "$APP/Contents/MacOS/APKExporter" "$APP/Contents/Resources/adb"
swift -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" scripts/make-icon.swift "$PROJECT_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$PROJECT_ROOT/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>APKExporter</string>
<key>CFBundleIdentifier</key><string>local.apkexporter.mac</string>
<key>CFBundleName</key><string>APK Exporter</string>
<key>CFBundleDisplayName</key><string>APK Exporter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>APK Exporter — 本地 Android APK 导出工具</string>
</dict></plist>
PLIST
# Bundle the Android SDK notices when available.
if [ -f "$(dirname "$ADB_BINARY")/NOTICE.txt" ]; then
  cp "$(dirname "$ADB_BINARY")/NOTICE.txt" "$APP/Contents/Resources/ADB-NOTICE.txt"
fi
codesign --force --sign - "$APP/Contents/Resources/adb"
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$PROJECT_ROOT/dist/APK-Exporter-$APP_VERSION-macOS-$BUILD_ARCH.zip"
BUILD_ARCH="$BUILD_ARCH" bash "$PROJECT_ROOT/scripts/build-dmg.sh"
echo "已生成：$APP"
