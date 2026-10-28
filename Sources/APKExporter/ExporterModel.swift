import AppKit
import SwiftUI
import APKExporterCore
import UniformTypeIdentifiers

struct ExporterNotice {
    let title: String
    let message: String
    var directory: URL? = nil
}

@MainActor
@Observable
final class ExporterModel {
    var devices: [AndroidDevice] = []
    var selectedDevice: String? {
        didSet { if oldValue != selectedDevice { loadPackages() } }
    }
    var packages: [InstalledPackage] = []
    var selection = Set<String>()
    var search = ""
    var includeSystem = false { didSet { loadPackages() } }
    var isLoading = false
    var isRefreshing = false
    var isExporting = false
    var isInstalling = false
    var showInstallSheet = false
    var installPath = ""
    var installPlan: InstallationPlan?
    var installError: String?
    var installMessage = ""
    var installSucceeded = false
    var status = "连接 Android 手机，开始导出"
    var exportDetail = ""
    var progress: Double = 0
    var results: [ExportResult] = []
    var notice: ExporterNotice?
    var destination: URL
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var generation = UUID()
    private let service: ADBService?

    init() {
        service = ADBService.locateExecutable().map { ADBService(executable: $0) }
        if let path = UserDefaults.standard.string(forKey: "exportDirectory") {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/APK Exports")
        }
    }

    var visiblePackages: [InstalledPackage] {
        packages.filter { $0.matches(search) }
    }
    var readyDevice: AndroidDevice? { devices.first { $0.id == selectedDevice && $0.isReady } }
    var selectedPackages: [InstalledPackage] { packages.filter { selection.contains($0.id) } }
    var isBusy: Bool { isExporting || isInstalling }
    var canExport: Bool { readyDevice != nil && !selection.isEmpty && !isLoading && !isBusy && !isRefreshing }
    var canInstall: Bool { readyDevice != nil && installPlan != nil && !isLoading && !isBusy && !isRefreshing && !installSucceeded }
    var destinationLabel: String {
        destination.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    func refresh() {
        guard !isBusy, !isRefreshing else { return }
        guard let service else {
            showError("未找到 ADB。请使用完整的 APK Exporter.app，或安装 Android platform-tools。")
            return
        }
        isRefreshing = true
        refreshTask = Task {
            defer { isRefreshing = false }
            do {
                let list = try await service.devices()
                devices = list
                let next = list.first { $0.id == selectedDevice && $0.isReady }?.id
                    ?? list.first(where: \.isReady)?.id
                if next == selectedDevice { loadPackages() } else { selectedDevice = next }
                if next == nil {
                    packages = []
                    selection = []
                    status = list.isEmpty ? "未发现设备，请用 USB 连接手机" : "请解锁手机，并允许 USB 调试"
                }
            } catch { showError(error.localizedDescription) }
        }
    }

    func loadPackages() {
        guard !isBusy else { return }
        loadTask?.cancel()
        generation = UUID()
        let current = generation
        packages = []
        selection = []
        guard let service, let device = readyDevice else { isLoading = false; return }
        isLoading = true
        let system = includeSystem
        loadTask = Task {
            defer { if generation == current { isLoading = false } }
            do {
                let list = try await service.packages(device: device.id, includeSystem: system)
                try Task.checkCancellation()
                guard generation == current else { return }
                packages = list
                status = "已连接 \(device.model) · \(list.count) 个应用"
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled && generation == current { showError(error.localizedDescription) }
            }
        }
    }

    func chooseDestination() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 APK 保存位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择此文件夹"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            UserDefaults.standard.set(url.path, forKey: "exportDirectory")
        }
    }

    func export(_ items: [InstalledPackage]? = nil) {
        guard !isBusy, !isLoading, !isRefreshing, let service, let device = readyDevice else { return }
        let apps = items ?? selectedPackages
        guard !apps.isEmpty else { return }
        isExporting = true
        progress = 0
        results = []
        let output = destination
        exportTask = Task {
            defer { isExporting = false; exportTask = nil }
            var failures: [String] = []
            for (index, app) in apps.enumerated() {
                if Task.isCancelled { break }
                status = "正在导出 \(index + 1) / \(apps.count)"
                do {
                    let result = try await service.export(package: app.id, device: device.id, destination: output) { completed, total, name in
                        await self.updateProgress(index: index, count: apps.count, completed: completed, total: total, name: name, package: app.id)
                    }
                    results.insert(result, at: 0)
                } catch {
                    if Task.isCancelled { break }
                    failures.append("\(app.id)：\(error.localizedDescription)")
                }
            }
            if Task.isCancelled {
                status = "导出已停止，已完成 \(results.count) 个应用"
            } else {
                progress = 1
                status = "导出完成：\(results.count) 个应用" + (failures.isEmpty ? "" : "，\(failures.count) 个失败")
            }
            exportDetail = ""
            selection.removeAll()
            let title = Task.isCancelled ? "导出已停止" : (failures.isEmpty ? "导出完成" : (results.isEmpty ? "导出失败" : "导出结束，部分失败"))
            let apkCount = results.reduce(0) { $0 + $1.apkFiles.count }
            var message = "成功导出 \(results.count) 个应用，共 \(apkCount) 个 APK。"
            if !results.isEmpty { message += "\n\n保存位置：\(output.path)" }
            if !failures.isEmpty { message += "\n\n失败详情：\n" + failures.joined(separator: "\n\n") }
            message += "\n\n已清空选中状态。"
            notice = ExporterNotice(title: title, message: message, directory: results.isEmpty ? nil : output)
        }
    }

    func clearSelection() {
        guard !isBusy else { return }
        selection.removeAll()
    }

    func openInstaller(path: URL? = nil) {
        guard !isBusy, !isLoading, !isRefreshing else { return }
        installPath = path?.path ?? ""
        prepareInstallation()
        showInstallSheet = true
    }

    func chooseInstallationPath() {
        guard !isInstalling else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 APK 或单个应用的导出文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.directoryURL = destination
        panel.prompt = "选择并预览"
        if panel.runModal() == .OK, let url = panel.url {
            installPath = url.path
            prepareInstallation()
        }
    }

    func prepareInstallation() {
        guard !isInstalling else { return }
        installPlan = nil
        installError = nil
        installMessage = ""
        installSucceeded = false
        guard !installPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { installPlan = try InstallationPlan.resolve(path: installPath) }
        catch { installError = error.localizedDescription }
    }

    func install() {
        guard canInstall, let plan = installPlan, let service, let device = readyDevice else { return }
        isInstalling = true
        installError = nil
        installMessage = "正在安装到 \(device.model)…请留意手机上的安装确认。"
        status = "正在安装 \(plan.apkFiles.count) 个 APK 到 \(device.model)"
        installTask = Task {
            defer { isInstalling = false; installTask = nil }
            do {
                try await service.install(plan, device: device.id)
                installSucceeded = true
                installMessage = "安装成功：已将 \(plan.apkFiles.count) 个 APK 安装到 \(device.model)。"
                status = "安装完成"
                isInstalling = false
                loadPackages()
            } catch {
                installMessage = ""
                installError = error.localizedDescription
                status = "安装失败，请查看安装窗口中的详情"
            }
        }
    }

    private func showError(_ message: String) {
        notice = ExporterNotice(title: "操作未完成", message: message)
    }

    private func updateProgress(index: Int, count: Int, completed: Int, total: Int, name: String, package: String) {
        progress = (Double(index) + Double(completed) / Double(max(total, 1))) / Double(count)
        exportDetail = "\(package) · \(name)（\(min(completed + 1, total))/\(total)）"
    }

    func cancelExport() { exportTask?.cancel() }

    func reveal(_ result: ExportResult) {
        NSWorkspace.shared.activateFileViewerSelecting([result.directory])
    }
}
