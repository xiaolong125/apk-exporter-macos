# APK Exporter for macOS

版本：**1.0.0**。

原生 SwiftUI 应用，连接 Android 手机后，一键导出已安装应用的原始 APK。内置 ADB，不需要单独安装 Android Studio。

## 使用

1. 从 [v1.0.0 Release](https://github.com/xiaolong125/apk-exporter-macos/releases/tag/v1.0.0) 下载 **Universal DMG**，打开后将 `APK Exporter.app` 拖入 `Applications`，然后从“应用程序”启动。要求 macOS 14 或更新版本，同一个 Universal 安装包同时支持 Apple Silicon 和 Intel Mac。
2. 手机开启开发者选项 → USB 调试，通过数据线连接 Mac，并在手机上允许调试。
3. 选择左侧设备，列表显示**真实应用名称和包名**。搜索框同时支持名称（如“汽水音乐”“微信”）和包名，不区分英文字母大小写。当前读取手机主用户（user 0），不读取工作资料或其他用户空间。
4. 点击应用右侧的“导出”，或勾选多个应用后点击“导出所选”。默认保存到 `~/Downloads/APK Exports`，可更改。
5. 完成后点击“在 Finder 中显示”。每个应用保存到独立目录，包含原始 APK、导出信息和安装说明。

点击“取消选择”可一次清空所有勾选（包括搜索结果之外已选的应用），快捷键为 `⌘⇧A`。导出结束会弹出结果提示，显示成功数量、保存位置及失败详情，并自动清空选中状态；提示中可直接打开导出文件夹。手动停止导出也会提示已完成数量并清空选择。

单 APK 应用会得到 `包名.apk`。拆分应用会得到 `base.apk` 及所有已安装的 `split_*.apk`，使用 `adb install-multiple -r *.apk` 一起安装。**导出不会合并、修改或重新签名 APK**，不包含应用数据。文件针对当前手机的架构和资源配置，不能保证适用于所有手机。

同名应用重复导出会创建新目录，不覆盖已有文件。导出失败或停止时清理本次未完成的应用目录，保留已经完成的导出。设备掉线时会显示错误，可重新连接并刷新。取消大文件导出会终止对应 ADB 子进程，不会关闭全局 ADB 服务。

## 构建

需要 Xcode 或匹配的 Swift 6 工具链，以及 Android SDK platform-tools 中的 `adb`。

```bash
git clone https://github.com/xiaolong125/apk-exporter-macos.git
cd apk-exporter-macos
bash scripts/build-app.sh
```

默认分别构建 `arm64` 和 `x86_64`，再合并为 Universal 应用。单架构构建可用 `BUILD_ARCH=x86_64 bash scripts/build-app.sh` 或 `BUILD_ARCH=arm64 bash scripts/build-app.sh`。`ADB_BINARY=/path/to/adb` 可指定要打包的 ADB；构建脚本会检查主程序与 ADB 均包含目标架构，Universal 构建需要双架构 ADB。

应用、带版本号的 DMG 和 ZIP 位于 `dist/`，应用版本由 `VERSION` 文件管理。DMG 包含应用、`Applications` 快捷方式和安装说明。若已有构建完成的应用，可运行 `bash scripts/build-dmg.sh` 单独生成 DMG。本地构建使用 ad hoc 签名；面向其他 Mac 正式分发时，需要开发者证书签名及 Apple 公证。

应用名称由手机的 PackageManager 读取，包含当前设备语言及已安装拆分资源中的名称。应用内置小型 `AppCatalog.jar`：通过 ADB 临时复制到 `/data/local/tmp`，在 shell 身份下运行，读取后删除；不在手机安装应用，不需要 Root，不读取账号或应用数据。单个名称缺失时保留完整包名，不再将包名片段当作应用名。

读取程序源码位于 `DeviceHelper/src/`，预编译资源随源码提交。修改读取程序后，使用 JDK、Android SDK 36、build-tools 36.0.0 和 Python 3 重新生成：

```bash
bash scripts/build-device-helper.sh
```

可通过 `ANDROID_JAR` 与 `D8_BINARY` 指定其他 SDK 路径。正常构建 Mac 应用及日常使用无需 Java、Python 或 Android SDK；构建 Mac 应用仍需提供前述 ADB。

## 验证

```bash
swift test --disable-sandbox --scratch-path .build \
  -Xswiftc -module-cache-path -Xswiftc .build/ModuleCache
```

测试覆盖多设备状态、真实名称与包名搜索、中文和特殊字符、读取名称后清理临时程序、列表解析、路径含空格、单包与拆分包导出、原始字节保持、重复导出、失败清理、无效包名、超时和取消。

可选真机测试会读取设备并把指定应用导出至临时目录，逐个比较手机与本机 APK 的 SHA-256，完成后清理；不会安装、卸载或修改手机应用：

```bash
APK_EXPORTER_LIVE_SERIAL=设备序列号 APK_EXPORTER_LIVE_PACKAGE=com.luna.music swift test --disable-sandbox \
  --filter ADBServiceTests.testLiveDeviceExport
```

ADB 来自本机 Android SDK，打包时附带其 `NOTICE.txt`。应用只通过本机 ADB 与所选设备通信，不设置远程服务，不上传 APK。
