import AppKit
import SwiftUI
import APKExporterCore

@main
struct APKExporterApp: App {
    @State private var model = ExporterModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("设备") {
                Button("刷新设备与应用") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.isExporting || model.isRefreshing)
                Button("导出所选应用") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(!model.canExport)
                Button("取消选择") { model.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.selection.isEmpty || model.isExporting)
            }
        }
    }
}

private enum Palette {
    static let ink = Color(red: 0.10, green: 0.16, blue: 0.22)
    static let muted = Color(red: 0.43, green: 0.49, blue: 0.53)
    static let green = Color(red: 0.05, green: 0.47, blue: 0.36)
    static let background = Color(red: 0.97, green: 0.98, blue: 0.97)
}

struct ContentView: View {
    @Bindable var model: ExporterModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 245)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                searchBar
                packageList
                footer
            }
            .background(.white)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.green)
        .task { model.refresh() }
        .alert(model.notice?.title ?? "提示", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            if let directory = model.notice?.directory {
                Button("打开导出文件夹") { NSWorkspace.shared.open(directory) }
            }
            Button("知道了", role: .cancel) { model.notice = nil }
        } message: { Text(model.notice?.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Palette.green, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("APK Exporter").font(.system(size: 16, weight: .bold))
                    Text("手机应用，轻松带走").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("已连接设备")
                    Spacer()
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isExporting || model.isRefreshing)
                    .help("刷新设备（⌘R）")
                }
                if model.isRefreshing { ProgressView().controlSize(.small) }
                if model.devices.isEmpty && !model.isRefreshing {
                    Text("尚未发现设备").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                ForEach(model.devices) { device in
                    Button {
                        if device.isReady { model.selectedDevice = device.id }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: device.id.hasPrefix("emulator-") ? "desktopcomputer" : "iphone.gen3")
                                .font(.system(size: 21)).frame(width: 23).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.model).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(device.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                                HStack(spacing: 4) {
                                    Circle().fill(device.isReady ? Palette.green : .orange).frame(width: 5, height: 5)
                                    Text(device.statusLabel).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                                }.foregroundStyle(device.isReady ? Palette.green : .orange)
                            }
                            Spacer(minLength: 0)
                            if model.selectedDevice == device.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green).font(.system(size: 12))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selectedDevice == device.id ? Color.white : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedDevice == device.id ? Palette.green.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isExporting || !device.isReady)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("保存位置")
                Image(systemName: "folder").foregroundStyle(Palette.green)
                Text(model.destinationLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted).lineLimit(3).textSelection(.enabled)
                Button("更改文件夹…") { model.chooseDestination() }
                    .font(.system(size: 12)).disabled(model.isExporting)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                Label("首次连接", systemImage: "cable.connector").font(.system(size: 12, weight: .semibold))
                Text("1. 手机开启开发者选项\n2. 打开 USB 调试\n3. 连接数据线，允许调试\n4. 点击右上方刷新按钮")
                    .font(.system(size: 11)).lineSpacing(5).foregroundStyle(Palette.muted)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))

            Label("本地导出 · 原版签名", systemImage: "checkmark.shield")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 18).padding(.bottom, 20)
        .background(Palette.background)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("应用导出").font(.system(size: 29, weight: .bold))
                Text("选择手机里的应用，一键保存 APK 到 Mac。")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Text("USB / ADB")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.green).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Palette.green.opacity(0.08), in: Capsule())
        }.padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 24)
    }

    private var searchBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索包名，例如 com.luna.music", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 13))
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                        .buttonStyle(.plain)
                }
            }
            .padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("\(model.visiblePackages.count) 个应用")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer()
                Toggle("显示系统应用", isOn: $model.includeSystem)
                    .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isExporting)
                Button("全选结果") { model.selection.formUnion(model.visiblePackages.map(\.id)) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.green)
                    .disabled(model.isExporting || model.visiblePackages.isEmpty)
                Button("取消选择") { model.clearSelection() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .disabled(model.isExporting || model.selection.isEmpty)
            }
        }.padding(.horizontal, 30).padding(.bottom, 16)
    }

    private var packageList: some View {
        VStack(spacing: 0) {
            Divider()
            if model.isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在读取手机应用…").foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.packages.isEmpty || model.visiblePackages.isEmpty {
                ContentUnavailableView {
                    Label(model.readyDevice == nil ? "连接你的 Android 手机" : "没有找到应用",
                          systemImage: model.readyDevice == nil ? "cable.connector" : "magnifyingglass")
                } description: {
                    Text(model.readyDevice == nil ? "开启 USB 调试并允许连接，然后点击刷新。" : "尝试其他包名，或开启“显示系统应用”。")
                } actions: {
                    if model.readyDevice == nil {
                        Button("刷新设备") { model.refresh() }.disabled(model.isRefreshing)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visiblePackages) { app in
                            appRow(app)
                            Divider().padding(.leading, 60)
                        }
                    }.padding(.horizontal, 24)
                }
            }
            if !model.results.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    sectionLabel("本次已导出 \(model.results.count) 个应用")
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.results) { result in
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                                    Text(result.package).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text("\(result.apkFiles.count) 个 APK · \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                    Button("在 Finder 中显示") { model.reveal(result) }.font(.system(size: 11))
                                }
                            }
                        }
                    }.frame(maxHeight: 82)
                }.padding(.horizontal, 30).padding(.vertical, 14)
                .background(Palette.green.opacity(0.035))
            }
        }
    }

    private func appRow(_ app: InstalledPackage) -> some View {
        HStack(spacing: 14) {
            Toggle("选择 \(app.id)", isOn: Binding(
                get: { model.selection.contains(app.id) },
                set: { if $0 { model.selection.insert(app.id) } else { model.selection.remove(app.id) } }
            )).labelsHidden().toggleStyle(.checkbox).disabled(model.isExporting)
            Image(systemName: "app.dashed")
                .font(.system(size: 22)).foregroundStyle(Palette.green)
                .frame(width: 42, height: 42)
                .background(Palette.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.title).font(.system(size: 13, weight: .semibold))
                Text(app.id).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            Spacer()
            Button { model.export([app]) } label: {
                Label("导出", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }.buttonStyle(.bordered).disabled(model.isExporting || model.isLoading || model.isRefreshing)
        }.padding(.vertical, 12).padding(.horizontal, 6)
        .background(model.selection.contains(app.id) ? Palette.green.opacity(0.035) : .clear)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isExporting {
                ProgressView(value: model.progress).tint(Palette.green)
                Text(model.exportDetail).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.muted).lineLimit(1)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(model.readyDevice == nil ? .orange : Palette.green).frame(width: 6, height: 6)
                        Text(model.status).font(.system(size: 12, weight: .medium))
                    }
                    Text("自动完整导出拆分 APK · 不包含应用数据")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if model.isExporting {
                    Button("停止导出") { model.cancelExport() }.controlSize(.large)
                } else {
                    if !model.selection.isEmpty {
                        Button("取消选择") { model.clearSelection() }.controlSize(.large)
                    }
                    Button { model.export() } label: {
                        Label(model.selection.isEmpty ? "导出所选应用" : "导出所选（\(model.selection.count)）", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.canExport).keyboardShortcut("e")
                }
            }
        }.padding(.horizontal, 30).padding(.vertical, 20)
        .background(Palette.background)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
    }
}
