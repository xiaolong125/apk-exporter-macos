import Foundation

public struct AndroidDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let state: String
    public let model: String
    public var isReady: Bool { state == "device" }
    public var statusLabel: String {
        switch state {
        case "device": "已连接"
        case "unauthorized": "请在手机上允许 USB 调试"
        case "offline": "设备离线，请重新连接"
        default: state
        }
    }
}

public struct InstalledPackage: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public var title: String { name }
    public init(id: String, name: String? = nil) {
        self.id = id
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = label.isEmpty ? id : label
    }

    public func matches(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || name.localizedCaseInsensitiveContains(text) || id.localizedCaseInsensitiveContains(text)
    }
}

public struct ExportResult: Identifiable, Sendable {
    public let id = UUID()
    public let package: String
    public let directory: URL
    public let apkFiles: [URL]
    public let bytes: Int64
}

public enum ExporterError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

// stdout/stderr go to files so a large ADB response cannot fill a pipe and hang.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    private var timeout = false

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func stop(timedOut: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        timeout = timedOut
        if let process, process.isRunning {
            process.terminate()
            // A stuck subprocess must not keep an export alive indefinitely.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    func didTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeout
    }
}

public struct ADBService: Sendable {
    public let executable: URL
    private let catalogArchive: URL?
    public init(executable: URL, catalogArchive: URL? = nil) {
        self.executable = executable
        self.catalogArchive = catalogArchive
            ?? Bundle.main.url(forResource: "AppCatalog", withExtension: "jar")
            ?? Bundle.module.url(forResource: "AppCatalog", withExtension: "jar")
    }

    public static func locateExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "adb", withExtension: nil),
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb")
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        let control = ProcessControl()
        let job = Task.detached(priority: .userInitiated) { () throws -> String in
            let fm = FileManager.default
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            let outURL = temp.appendingPathComponent("stdout")
            let errURL = temp.appendingPathComponent("stderr")
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL)
            let err = try FileHandle(forWritingTo: errURL)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = err
            try control.start(process)
            let timer = DispatchWorkItem { control.stop(timedOut: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            process.waitUntilExit()
            timer.cancel()
            if control.didTimeout() { throw ExporterError.message("ADB 响应超时，请检查手机连接后重试。") }
            let output = String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
            let error = String(decoding: try Data(contentsOf: errURL), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw ExporterError.message((error + "\n" + output).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return output
        }
        return try await withTaskCancellationHandler {
            let value = try await job.value
            try Task.checkCancellation()
            return value
        } onCancel: { control.stop() }
    }

    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List "), !line.hasPrefix("*"),
                  ["device", "offline", "unauthorized", "recovery", "sideload", "no"].contains(fields[1]) else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }?
                .dropFirst(6).replacingOccurrences(of: "_", with: " ") ?? fields[0]
            return AndroidDevice(id: fields[0], state: fields[1], model: model)
        }
    }

    public static func parsePackages(_ output: String) -> [InstalledPackage] {
        Set(output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("package:") else { return nil }
            let value = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
            return value
        }).sorted().map { InstalledPackage(id: $0) }
    }

    public static func parseAPKPaths(_ output: String) throws -> [String] {
        let paths = output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("package:") else { return nil }
            return String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && $0.hasSuffix(".apk") }),
              Set(paths.map { URL(fileURLWithPath: $0).lastPathComponent }).count == paths.count else {
            throw ExporterError.message("未找到有效的 APK 文件。应用可能已卸载，或不在手机的主用户空间中。")
        }
        return paths
    }

    public func devices() async throws -> [AndroidDevice] {
        Self.parseDevices(try await run(["devices", "-l"]))
    }

    public func packages(device: String, includeSystem: Bool) async throws -> [InstalledPackage] {
        var args = ["-s", device, "shell", "pm", "list", "packages", "--user", "0"]
        if !includeSystem { args.append("-3") }
        let packages = Self.parsePackages(try await run(args))
        guard !packages.isEmpty else { return [] }
        guard let catalogArchive else {
            throw ExporterError.message("应用名称读取组件缺失，请重新下载完整的 APK Exporter.app。")
        }
        let remote = "/data/local/tmp/apk-exporter-catalog-\(UUID().uuidString).jar"
        let output: String
        do {
            _ = try await run(["-s", device, "push", catalogArchive.path, remote])
            output = try await run(["-s", device, "shell", "CLASSPATH=\(remote)", "app_process",
                                    "/system/bin", "local.apkexporter.AppCatalog", includeSystem ? "all" : "third-party"], timeout: 90)
        } catch {
            await removeCatalog(device: device, remote: remote)
            throw error
        }
        await removeCatalog(device: device, remote: remote)
        try Task.checkCancellation()
        return try Self.applyCatalog(output, to: packages)
    }

    private func removeCatalog(device: String, remote: String) async {
        // Cleanup also runs when the parent list operation has been cancelled.
        await Task.detached {
            _ = try? await self.run(["-s", device, "shell", "rm", "-f", remote], timeout: 10)
        }.value
    }

    public static func applyCatalog(_ output: String, to packages: [InstalledPackage]) throws -> [InstalledPackage] {
        let prefix = "APK_EXPORTER_CATALOG:"
        guard let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix(prefix) }),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8) else {
            throw ExporterError.message("未能读取应用名称，请重新连接手机后刷新。")
        }
        struct Label: Decodable { let id: String; let name: String }
        let labels: [Label]
        do { labels = try JSONDecoder().decode([Label].self, from: data) }
        catch { throw ExporterError.message("手机返回的应用名称列表格式无效，请刷新重试。") }
        var names: [String: String] = [:]
        for label in labels { names[label.id] = label.name }
        // The authoritative list comes from pm with explicit --user 0 and -3.
        return packages.map { InstalledPackage(id: $0.id, name: names[$0.id]) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    public func export(package: String, device: String, destination: URL,
                       progress: @escaping @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> ExportResult {
        guard !package.isEmpty, package.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else {
            throw ExporterError.message("无效的应用包名。")
        }
        let paths = try Self.parseAPKPaths(try await run(["-s", device, "shell", "pm", "path", "--user", "0", package]))
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // Export into a hidden staging folder; publish only after every APK succeeds.
        let token = UUID().uuidString
        let staging = destination.appendingPathComponent(".export-\(token)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        var names: [String] = []
        var bytes: Int64 = 0
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            let name = paths.count == 1 ? "\(package).apk" : URL(fileURLWithPath: path).lastPathComponent
            await progress(index, paths.count, name)
            let target = staging.appendingPathComponent(name)
            _ = try await run(["-s", device, "pull", path, target.path], timeout: 600)
            let attributes = try fm.attributesOfItem(atPath: target.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let handle = try FileHandle(forReadingFrom: target)
            let magic = try handle.read(upToCount: 4)
            try handle.close()
            guard size > 4, magic == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw ExporterError.message("\(name) 导出不完整，请重试。")
            }
            bytes += size
            names.append(name)
        }
        try Task.checkCancellation()
        let metadata: [String: Any] = [
            "package": package, "device": device, "files": names,
            "bytes": bytes, "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "signature": "Original APK files; no modification or re-signing."
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("export-info.json"))
        let instructions = """
        APK 导出：\(package)
        导出过程未修改或重新签名 APK，保留原版签名。
        文件数量：\(names.count)

        在此目录打开终端，执行：
        \(names.count == 1 ? "adb install -r \(names[0])" : "adb install-multiple -r *.apk")

        连接多台设备时，在 adb 后添加 -s 设备序列号。
        拆分 APK 必须一起安装，单独安装 base.apk 可能失败。
        仅包含当前设备已安装的架构与资源，不保证适用于所有 Android 设备。
        不包含账号、设置等应用数据。
        """
        try instructions.write(to: staging.appendingPathComponent("安装说明.txt"), atomically: true, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = destination.appendingPathComponent("\(package)_\(formatter.string(from: Date()))_\(token.prefix(6))")
        try fm.moveItem(at: staging, to: directory)
        await progress(paths.count, paths.count, "完成")
        return ExportResult(package: package, directory: directory,
                            apkFiles: names.map { directory.appendingPathComponent($0) }, bytes: bytes)
    }
}
