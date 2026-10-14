// swift-tools-version: 6.0
// SwiftPM 模块与系统依赖，by AI.Coding。
import PackageDescription
let package = Package(
    name: "LocalClip", platforms: [.macOS(.v15)],
    products: [.library(name: "LocalClipCore", targets: ["LocalClipCore"]),
               .library(name: "LocalClipMac", targets: ["LocalClipMac"]),
               .executable(name: "LocalClip", targets: ["LocalClip"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        // 更新事务独立于剪贴板存储，辅助进程不加载采集服务，by AI.Coding。
        .target(name: "LocalClipUpdateKit"),
        .executableTarget(name: "LocalClipUpdater", dependencies: ["LocalClipUpdateKit"]),
        .executableTarget(name: "LocalClipUpdateTool", dependencies: ["LocalClipUpdateKit"]),
        .target(name: "LocalClipCore", dependencies: ["CSQLite"]),
        .target(name: "LocalClipMac", dependencies: ["LocalClipCore", "LocalClipUpdateKit"], resources: [.process("Resources")]),
        .executableTarget(name: "LocalClip", dependencies: ["LocalClipMac"]),
        .testTarget(name: "LocalClipCoreTests", dependencies: ["LocalClipCore", "CSQLite"]),
        .testTarget(name: "LocalClipIntegrationTests", dependencies: ["LocalClipCore", "LocalClipMac"], resources: [.copy("Fixtures/PasteboardSoakWriter.m")])
    ])
