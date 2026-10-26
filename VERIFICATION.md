# 验证记录

日期：2026-10-26。构建环境：Apple Silicon Mac、Xcode Swift 6.2；应用最低系统 macOS 14。

- 9 项自动化测试通过：设备状态、包名列表、APK 路径、单 APK、拆分 APK、重复导出、失败清理、超时、取消及无效输入（部分归在同一测试中）。可选真机测试默认跳过。
- 三星 SM-S918U1 真机：成功导出 `com.luna.music`，单 APK，共 127,390,687 字节。SHA-256 与手机原文件一致。
- 同一真机：成功导出 `com.anthropic.claude`，4 个 APK，共 56,568,040 字节。所有 APK 的 SHA-256 分别与手机原文件一致。
- 实际启动打包后的 `.app`，识别三星真机及模拟器；搜索 `com.luna.music`，点击行内“导出”，界面显示“导出完成：1 个应用”，并显示 127.4 MB 和 Finder 入口。
- `.app` 通过 `codesign --verify --deep --strict` 本地签名验证，Info.plist 格式有效，ZIP 完整性验证通过。
- 1.0.0 DMG 通过 `hdiutil verify` 完整性校验，并以只读方式挂载验证：包含版本为 1.0.0 的应用、指向 `/Applications` 的快捷方式及安装说明；镜像内应用通过严格签名校验，验证后已推出。

当前产物为 arm64 本地签名版本，未进行开发者证书签名或 Apple 公证。未在 Intel Mac 上测试。应用列表按包名显示；读取主用户空间，导出原始 APK，不导出应用数据、不合并或重新签名 APK。
