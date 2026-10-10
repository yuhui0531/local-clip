// swift-tools-version: 6.2
// SwiftPM 模块与系统依赖，by AI.Coding。
import PackageDescription
let package = Package(
    name: "LocalClip", platforms: [.macOS(.v15)],
    products: [.library(name: "LocalClipCore", targets: ["LocalClipCore"]),
               .library(name: "LocalClipMac", targets: ["LocalClipMac"]),
               .executable(name: "LocalClip", targets: ["LocalClip"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LocalClipCore", dependencies: ["CSQLite"]),
        .target(name: "LocalClipMac", dependencies: ["LocalClipCore"], resources: [.process("Resources")]),
        .executableTarget(name: "LocalClip", dependencies: ["LocalClipMac"]),
        .testTarget(name: "LocalClipCoreTests", dependencies: ["LocalClipCore", "CSQLite"], swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])], linkerSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])]),
        .testTarget(name: "LocalClipIntegrationTests", dependencies: ["LocalClipCore", "LocalClipMac"], swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])], linkerSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])])
    ])
