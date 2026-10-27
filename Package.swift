// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APKExporter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "APKExporter", targets: ["APKExporter"])],
    targets: [
        .target(name: "APKExporterCore", resources: [.copy("Resources/AppCatalog.jar")]),
        .executableTarget(name: "APKExporter", dependencies: ["APKExporterCore"]),
        .testTarget(name: "APKExporterCoreTests", dependencies: ["APKExporterCore"])
    ]
)
