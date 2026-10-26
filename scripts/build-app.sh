#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.build/ModuleCache"
BUILD_ARCH="${BUILD_ARCH:-universal}"
case "$BUILD_ARCH" in
  universal) TARGET_ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) TARGET_ARCHS=("$BUILD_ARCH") ;;
  *) echo "不支持的 BUILD_ARCH：$BUILD_ARCH（可选 universal、arm64、x86_64）" >&2; exit 1 ;;
esac
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
ADB_BINARY="${ADB_BINARY:-$HOME/Library/Android/sdk/platform-tools/adb}"
if [ ! -x "$ADB_BINARY" ]; then
  ADB_BINARY="$(command -v adb || true)"
fi
if [ ! -x "$ADB_BINARY" ]; then
  echo "未找到 ADB。请安装 platform-tools 或通过 ADB_BINARY 指定路径。" >&2
  exit 1
fi
lipo "$ADB_BINARY" -verify_arch "${TARGET_ARCHS[@]}"
BUILT_BINARIES=()
for TARGET_ARCH in "${TARGET_ARCHS[@]}"; do
  swift build -c release --arch "$TARGET_ARCH" --disable-sandbox --scratch-path .build \
    -Xswiftc -module-cache-path -Xswiftc "$PROJECT_ROOT/.build/ModuleCache"
  BIN_DIR="$(swift build -c release --arch "$TARGET_ARCH" --disable-sandbox --scratch-path .build --show-bin-path)"
  BUILT_BINARIES+=("$BIN_DIR/APKExporter")
done
APP="$PROJECT_ROOT/dist/APK Exporter.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROJECT_ROOT/.build/AppIcon.iconset"
if [ "$BUILD_ARCH" = universal ]; then
  lipo -create "${BUILT_BINARIES[@]}" -output "$APP/Contents/MacOS/APKExporter"
else
  cp "${BUILT_BINARIES[0]}" "$APP/Contents/MacOS/APKExporter"
fi
cp "$ADB_BINARY" "$APP/Contents/Resources/adb"
lipo "$APP/Contents/MacOS/APKExporter" -verify_arch "${TARGET_ARCHS[@]}"
lipo "$APP/Contents/Resources/adb" -verify_arch "${TARGET_ARCHS[@]}"
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
