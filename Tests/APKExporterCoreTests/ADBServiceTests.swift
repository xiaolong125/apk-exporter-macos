import XCTest
import CryptoKit
@testable import APKExporterCore

@MainActor
final class ADBServiceTests: XCTestCase {
    func testDeviceStatesAndModels() {
        let devices = ADBService.parseDevices("""
        List of devices attached
        phone123 device usb:1 model:Pixel_9_Pro transport_id:1
        locked unauthorized usb:2 transport_id:2
        emulator-5554 offline transport_id:3
        * daemon started successfully
        """)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].model, "Pixel 9 Pro")
        XCTAssertTrue(devices[0].isReady)
        XCTAssertFalse(devices[1].isReady)
        XCTAssertFalse(devices[2].isReady)
    }

    func testPackageParsingIgnoresDiagnosticsAndDuplicates() {
        let packages = ADBService.parsePackages("package:com.z.app\r\nError: user 150\npackage:com.a.app\npackage:com.z.app\npackage:\n")
        XCTAssertEqual(packages.map(\.id), ["com.a.app", "com.z.app"])
    }

    func testAPKPathsMustExistAndHaveUniqueFilenames() throws {
        XCTAssertThrowsError(try ADBService.parseAPKPaths(""))
        XCTAssertThrowsError(try ADBService.parseAPKPaths("package:../../base.apk"))
        XCTAssertThrowsError(try ADBService.parseAPKPaths("package:/data/a/base.apk\npackage:/data/b/base.apk"))
        XCTAssertEqual(try ADBService.parseAPKPaths("package:/data/app/~~abc==/base.apk\r\npackage:/data/app/~~abc==/split_en.apk\r\n").count, 2)
    }

    private func fixture(failSplit: Bool = false, single: Bool = false) throws -> (URL, ADBService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("APK Exporter tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake adb")
        let script = """
        #!/bin/sh
        if [ "$1" = "hang" ]; then exec sleep 10; fi
        if [ "$1" = "devices" ]; then
          printf 'List of devices attached\\nfixture device model:Test_Phone\\n'
        elif [ "$3" = "shell" ] && [ "$5" = "path" ]; then
          printf 'package:/data/app/path with spaces/base.apk\\n'
          \(single ? "" : "printf 'package:/data/app/path with spaces/split_config.en.apk\\n'")
        elif [ "$3" = "pull" ]; then
          \(failSplit ? "case \"$4\" in *split*) printf 'device disconnected' >&2; exit 1;; esac" : "")
          printf 'PK\\003\\004original-content:%s' "$4" > "$5"
        else
          printf 'package:com.example.app\\n'
        fi
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (root, ADBService(executable: executable))
    }

    func testSplitExportPreservesFilesAndDoesNotOverwrite() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("output with spaces")
        let result = try await service.export(package: "com.example.app", device: "fixture", destination: destination)
        XCTAssertEqual(result.apkFiles.map(\.lastPathComponent), ["base.apk", "split_config.en.apk"])
        for url in result.apkFiles {
            let expected = Data([0x50, 0x4b, 0x03, 0x04]) + Data("original-content:/data/app/path with spaces/\(url.lastPathComponent)".utf8)
            XCTAssertEqual(try Data(contentsOf: url), expected)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.directory.appendingPathComponent("export-info.json").path))
        let next = try await service.export(package: "com.example.app", device: "fixture", destination: destination)
        XCTAssertNotEqual(result.directory, next.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.apkFiles[0].path))
    }

    func testSingleExportUsesPackageFilename() async throws {
        let (root, service) = try fixture(single: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await service.export(package: "com.example.app", device: "fixture", destination: root.appendingPathComponent("out"))
        XCTAssertEqual(result.apkFiles.map(\.lastPathComponent), ["com.example.app.apk"])
        let text = try String(contentsOf: result.directory.appendingPathComponent("安装说明.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("adb install -r com.example.app.apk"))
    }

    func testFailedSplitCleansUpPartialExport() async throws {
        let (root, service) = try fixture(failSplit: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out")
        do {
            _ = try await service.export(package: "com.example.app", device: "fixture", destination: destination)
            XCTFail("Should reject incomplete split export")
        } catch { XCTAssertTrue(error.localizedDescription.contains("device disconnected")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
    }

    func testInvalidPackageRejectedBeforeCommand() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await service.export(package: "../unsafe", device: "fixture", destination: root)
            XCTFail("Should reject unsafe package")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无效")) }
    }

    func testCommandTimeout() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        do {
            _ = try await service.run(["hang"], timeout: 0.1)
            XCTFail("Should time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCommandCancellation() async throws {
        let (root, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { try await service.run(["hang"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Should cancel")
        } catch {}
    }

    func testLiveDeviceExport() async throws {
        guard let serial = ProcessInfo.processInfo.environment["APK_EXPORTER_LIVE_SERIAL"],
              let adb = ADBService.locateExecutable() else { throw XCTSkip("Optional live device test") }
        let service = ADBService(executable: adb)
        let package = ProcessInfo.processInfo.environment["APK_EXPORTER_LIVE_PACKAGE"] ?? "com.luna.music"
        let devices = try await service.devices()
        XCTAssertTrue(devices.contains { $0.id == serial && $0.isReady })
        let packages = try await service.packages(device: serial, includeSystem: false)
        XCTAssertTrue(packages.contains { $0.id == package })
        let remotePaths = try ADBService.parseAPKPaths(try await service.run(["-s", serial, "shell", "pm", "path", "--user", "0", package]))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("APKExporter-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try await service.export(package: package, device: serial, destination: destination)
        XCTAssertEqual(result.apkFiles.count, remotePaths.count)
        XCTAssertGreaterThan(result.bytes, 0)
        for (remote, local) in zip(remotePaths, result.apkFiles) {
            let quotedPath = "'" + remote.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let output = try await service.run(["-s", serial, "shell", "toybox", "sha256sum", quotedPath])
            let remoteHash = String(output.split(whereSeparator: \.isWhitespace).first ?? "")
            let localHash = SHA256.hash(data: try Data(contentsOf: local)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(localHash, remoteHash, "Exported APK must be byte-identical to the installed APK")
        }
        print("Live export verified: \(result.bytes) bytes from \(serial)")
    }
}
