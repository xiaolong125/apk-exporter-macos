import XCTest
@testable import APKExporterCore

@MainActor
final class InstallationTests: XCTestCase {
    private func fixture(names: [String], manifest: [String]? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APK install tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try (Data([0x50, 0x4b, 0x03, 0x04]) + Data("fixture APK content".utf8))
                .write(to: root.appendingPathComponent(name))
        }
        if let manifest {
            try JSONSerialization.data(withJSONObject: ["files": manifest])
                .write(to: root.appendingPathComponent("export-info.json"))
        }
        return root
    }

    private func adb(in root: URL, output: String = "Performing Streamed Install\nSuccess", exit: Int = 0) throws -> ADBService {
        let executable = root.appendingPathComponent("fake adb")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(root.appendingPathComponent("arguments").path)'
        cat <<'INSTALL_OUTPUT'
        \(output)
        INSTALL_OUTPUT
        exit \(exit)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return ADBService(executable: executable)
    }

    func testSingleAPKInstallationPreservesArgumentBoundariesAndBytes() async throws {
        let root = try fixture(names: ["app name 中文.apk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app name 中文.apk")
        let before = try Data(contentsOf: file)
        let plan = try InstallationPlan.resolve(path: "  \(file.path)\n")
        XCTAssertFalse(plan.isSplit)
        try await adb(in: root).install(plan, device: "selected-phone")
        let args = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["-s", "selected-phone", "install", "-r", "--user", "0", file.path])
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testExportedSplitFileSelectsWholeExportAndInstallsTogether() async throws {
        let names = ["base.apk", "split_config.arm64.apk", "split_config.zh.apk"]
        let root = try fixture(names: names, manifest: names)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try InstallationPlan.resolve(path: root.appendingPathComponent(names[2]).path)
        XCTAssertEqual(plan.source.path, root.path)
        XCTAssertEqual(plan.apkFiles.map(\.lastPathComponent), names)
        XCTAssertEqual(try InstallationPlan.resolve(path: root.path), plan)
        try await adb(in: root).install(plan, device: "other-phone")
        let args = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["-s", "other-phone", "install-multiple", "-r", "--user", "0"] + plan.apkFiles.map(\.path))
    }

    func testIncompleteOrMixedExportIsRejected() throws {
        let names = ["base.apk", "split_config.en.apk"]
        let root = try fixture(names: [names[0]], manifest: names)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains(names[1]))
        }
        try Data([0x50, 0x4b, 0x03, 0x04, 1]).write(to: root.appendingPathComponent(names[1]))
        XCTAssertEqual(try InstallationPlan.resolve(path: root.path).apkFiles.count, 2)
        try Data([0x50, 0x4b, 0x03, 0x04, 1]).write(to: root.appendingPathComponent("unrelated.apk"))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
        try JSONSerialization.data(withJSONObject: ["files": ["../outside.apk"]])
            .write(to: root.appendingPathComponent("export-info.json"))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
    }

    func testPlainSplitFolderAndBaseSelectionResolveAllFiles() throws {
        let root = try fixture(names: ["base.apk", "split_config.en.apk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try InstallationPlan.resolve(path: root.appendingPathComponent("base.apk").path)
        XCTAssertTrue(plan.isSplit)
        XCTAssertEqual(plan.apkFiles.count, 2)
    }

    func testInvalidInputsAndMultipleAppRootAreRejected() throws {
        let root = try fixture(names: ["split_config.en.apk"])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.appendingPathComponent("split_config.en.apk").path))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.appendingPathComponent("missing.apk").path))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: ""))
        try FileManager.default.removeItem(at: root.appendingPathComponent("split_config.en.apk"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("one export"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
        try Data("not an APK".utf8).write(to: root.appendingPathComponent("invalid.apk"))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
        try Data([0x50, 0x4b, 0x03, 0x04, 1]).write(to: root.appendingPathComponent("another.apk"))
        XCTAssertThrowsError(try InstallationPlan.resolve(path: root.path))
    }

    func testInstallationRequiresExplicitSuccessAndReportsADBFailure() async throws {
        let root = try fixture(names: ["app.apk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try InstallationPlan.resolve(path: root.path)
        for (output, exit) in [("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]", 0),
                               ("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]", 1),
                               ("Success\nFailure [INSTALL_FAILED_MISSING_SPLIT]", 0),
                               ("", 0)] {
            do {
                try await adb(in: root, output: output, exit: exit).install(plan, device: "phone")
                XCTFail("Must reject failure or missing success")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(output.isEmpty ? "未返回安装成功" : "INSTALL_FAILED"))
            }
        }
    }

    func testChangedExportIsRejectedBeforeInvokingADB() async throws {
        let names = ["base.apk", "split_config.en.apk"]
        let root = try fixture(names: names, manifest: names)
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try InstallationPlan.resolve(path: root.path)
        let service = try adb(in: root)
        try FileManager.default.removeItem(at: plan.apkFiles[1])
        do {
            try await service.install(plan, device: "phone")
            XCTFail("Should reject a missing split")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不完整")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments").path))
    }
}
