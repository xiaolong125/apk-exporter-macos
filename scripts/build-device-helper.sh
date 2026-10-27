#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_SDK_ROOT_PATH="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ANDROID_JAR="${ANDROID_JAR:-$ANDROID_SDK_ROOT_PATH/platforms/android-36/android.jar}"
D8_BINARY="${D8_BINARY:-$ANDROID_SDK_ROOT_PATH/build-tools/36.0.0/d8}"
if [ ! -f "$ANDROID_JAR" ] || [ ! -x "$D8_BINARY" ]; then
  echo "需要 Android SDK platform 36 和 build-tools 36.0.0；也可指定 ANDROID_JAR 与 D8_BINARY。" >&2
  exit 1
fi
HELPER_BUILD="$PROJECT_ROOT/.build/device-helper"
mkdir -p "$HELPER_BUILD/classes" "$HELPER_BUILD/dex" "$PROJECT_ROOT/Sources/APKExporterCore/Resources"
javac --release 8 -encoding UTF-8 -cp "$ANDROID_JAR" \
  -d "$HELPER_BUILD/classes" "$PROJECT_ROOT/DeviceHelper/src/local/apkexporter/AppCatalog.java"
"$D8_BINARY" --min-api 24 --lib "$ANDROID_JAR" --output "$HELPER_BUILD/dex" \
  "$HELPER_BUILD/classes/local/apkexporter/AppCatalog.class"
# A fixed timestamp makes the small resource archive reproducible.
python3 - "$HELPER_BUILD/dex/classes.dex" "$PROJECT_ROOT/Sources/APKExporterCore/Resources/AppCatalog.jar" <<'PY'
import pathlib, sys, zipfile
info = zipfile.ZipInfo('classes.dex', (2020, 1, 1, 0, 0, 0))
info.compress_type = zipfile.ZIP_DEFLATED
with zipfile.ZipFile(sys.argv[2], 'w') as archive:
    archive.writestr(info, pathlib.Path(sys.argv[1]).read_bytes())
PY
echo "已生成 AppCatalog.jar"
