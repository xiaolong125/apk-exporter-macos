#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
APP_VERSION="$(tr -d '[:space:]' < VERSION)"
APP="$PROJECT_ROOT/dist/APK Exporter.app"
if [ ! -d "$APP" ]; then
  echo "请先运行 bash scripts/build-app.sh 构建应用。" >&2
  exit 1
fi
if [ -z "${BUILD_ARCH:-}" ]; then
  APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/APKExporter")"
  case "$APP_ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) BUILD_ARCH=universal ;;
    arm64|x86_64) BUILD_ARCH="$APP_ARCHS" ;;
    *) echo "无法识别应用架构：$APP_ARCHS" >&2; exit 1 ;;
  esac
fi
case "$BUILD_ARCH" in
  universal) TARGET_ARCHS=(arm64 x86_64) ;;
  arm64|x86_64) TARGET_ARCHS=("$BUILD_ARCH") ;;
  *) echo "不支持的 BUILD_ARCH：$BUILD_ARCH" >&2; exit 1 ;;
esac
lipo "$APP/Contents/MacOS/APKExporter" -verify_arch "${TARGET_ARCHS[@]}"
lipo "$APP/Contents/Resources/adb" -verify_arch "${TARGET_ARCHS[@]}"
DMG="$PROJECT_ROOT/dist/APK-Exporter-$APP_VERSION-macOS-$BUILD_ARCH.dmg"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$ACTUAL_VERSION" != "$APP_VERSION" ]; then
  echo "应用版本与 VERSION 不一致，请先重新构建应用。" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_ROOT/.build"
STAGING_DIR="$(mktemp -d "$PROJECT_ROOT/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP" "$STAGING_DIR/APK Exporter.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/安装说明.txt" <<'TEXT'
APK Exporter 安装说明

将 APK Exporter.app 拖入 Applications（应用程序）文件夹，完成后推出此磁盘。
从“应用程序”打开 APK Exporter，连接开启 USB 调试的 Android 手机，并允许调试。

系统要求：macOS 14 或更新版本。Universal 安装包同时支持 Apple Silicon 与 Intel Mac；单架构安装包请与 Mac 芯片类型匹配。
当前版本使用本地 ad hoc 签名，尚未进行 Apple 开发者证书签名或公证。

源码与版本下载：https://github.com/xiaolong125/apk-exporter-macos
TEXT
hdiutil create -volname "APK Exporter $APP_VERSION" -srcfolder "$STAGING_DIR" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify "$DMG"
echo "已生成：$DMG"
