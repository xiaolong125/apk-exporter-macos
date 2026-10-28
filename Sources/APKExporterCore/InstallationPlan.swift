import Foundation

public struct InstallationPlan: Sendable, Equatable {
    public let source: URL
    public let apkFiles: [URL]
    public let bytes: Int64
    public var isSplit: Bool { apkFiles.count > 1 }

    /// An exported APK belongs to its whole export, including all split resources.
    public static func resolve(path: String) throws -> InstallationPlan {
        let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExporterError.message("请选择 APK 文件或单个应用的导出文件夹。") }
        let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &directory) else {
            throw ExporterError.message("路径不存在，请检查 APK 路径。")
        }
        var source = url
        if !directory.boolValue {
            guard url.pathExtension.lowercased() == "apk" else {
                throw ExporterError.message("请选择 .apk 文件或包含 APK 的文件夹。")
            }
            let parent = url.deletingLastPathComponent()
            let siblings = try apkFiles(in: parent)
            if fm.fileExists(atPath: parent.appendingPathComponent("export-info.json").path)
                || url.lastPathComponent.hasPrefix("split_")
                || (url.lastPathComponent == "base.apk" && siblings.count > 1) {
                source = parent
                directory = true
            }
        }
        let files: [URL]
        if directory.boolValue {
            let available = try apkFiles(in: source)
            let metadata = source.appendingPathComponent("export-info.json")
            if fm.fileExists(atPath: metadata.path) {
                struct Manifest: Decodable { let files: [String] }
                let manifest: Manifest
                do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: metadata)) }
                catch { throw ExporterError.message("导出信息无法读取，请选择完整的应用导出文件夹。") }
                guard !manifest.files.isEmpty, Set(manifest.files).count == manifest.files.count,
                      manifest.files.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0.lowercased().hasSuffix(".apk") }) else {
                    throw ExporterError.message("导出信息中的 APK 文件列表无效。")
                }
                let names = Set(available.map(\.lastPathComponent))
                let missing = Set(manifest.files).subtracting(names).sorted()
                guard missing.isEmpty else {
                    throw ExporterError.message("导出文件不完整，缺少：\(missing.joined(separator: "、"))。请重新完整导出后安装。")
                }
                guard names == Set(manifest.files) else {
                    throw ExporterError.message("文件夹中有导出信息之外的 APK，请使用单个应用的完整导出文件夹。")
                }
                files = manifest.files.map { source.appendingPathComponent($0) }
            } else {
                guard !available.isEmpty else {
                    throw ExporterError.message("此文件夹没有 APK，请选择单个应用的导出文件夹，不要选择包含多个应用的上级目录。")
                }
                guard available.count == 1 || (available.contains { $0.lastPathComponent == "base.apk" }
                    && available.allSatisfy { $0.lastPathComponent == "base.apk" || $0.lastPathComponent.hasPrefix("split_") }) else {
                    throw ExporterError.message("无法确认这些 APK 属于同一个应用，请选择单个 APK 或包含 base.apk 和 split_*.apk 的文件夹。")
                }
                files = available
            }
        } else {
            files = [url]
        }
        guard files.count > 1 || !files[0].lastPathComponent.hasPrefix("split_") else {
            throw ExporterError.message("不能单独安装拆分 APK，请选择同时包含 base.apk 的完整导出文件夹。")
        }
        var bytes: Int64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 4,
                  try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
                throw ExporterError.message("\(file.lastPathComponent) 不是有效的 APK 文件或文件不完整。")
            }
            bytes += Int64(values.fileSize ?? 0)
        }
        return InstallationPlan(source: source, apkFiles: files, bytes: bytes)
    }

    private static func apkFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension ADBService {
    public func install(_ plan: InstallationPlan, device: String) async throws {
        // Recheck completeness immediately before handing files to ADB.
        let current = try InstallationPlan.resolve(path: plan.source.path)
        guard current == plan else {
            throw ExporterError.message("APK 文件已变化，请重新选择路径并确认文件列表。")
        }
        let command = plan.isSplit ? "install-multiple" : "install"
        let output = try await run(["-s", device, command, "-r", "--user", "0"] + plan.apkFiles.map(\.path), timeout: 600)
        let lines = output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains("Success"), !lines.contains(where: { $0.contains("Failure [") || $0.hasPrefix("Error:") }) else {
            throw ExporterError.message(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ADB 未返回安装成功，请检查手机上的安装确认提示后重试。" : output)
        }
    }
}
