// 更新故障只操作临时目录，不安装、不启动应用，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipUpdateKit

struct CommentUpdateTests {
    /// 任一半恢复失败仍尝试另一半；重试不能再次交换已恢复的数据或应用。
    @Test(arguments: ["data", "app"])
    func partialRollbackRetriesOnlyPendingHalf(_ failure: String) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("app"), candidate = root.appendingPathComponent("candidate"), data = root.appendingPathComponent("data")
        for (url, text) in [(app, "old-app"), (candidate, "new-app"), (data, "old-data")] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url.appendingPathComponent("value"))
        }
        let transaction = try UpdateTransaction(target: app, candidate: candidate, dataDirectory: data, backupDirectory: root.appendingPathComponent("backup"))
        try transaction.prepare(); try transaction.replaceApp()
        try Data("new-data".utf8).write(to: data.appendingPathComponent("value"))
        let blocked = failure == "data" ? transaction.dataBackup : candidate
        let parked = root.appendingPathComponent("parked")
        try fm.moveItem(at: blocked, to: parked)
        #expect(throws: (any Error).self) { try transaction.rollback() }
        #expect(transaction.replaced)
        if failure == "data" { #expect(try String(contentsOf: app.appendingPathComponent("value"), encoding: .utf8) == "old-app") }
        else { #expect(try String(contentsOf: data.appendingPathComponent("value"), encoding: .utf8) == "old-data") }
        try fm.moveItem(at: parked, to: blocked)
        try transaction.rollback(); try transaction.rollback()
        #expect(!transaction.replaced)
        #expect(try String(contentsOf: app.appendingPathComponent("value"), encoding: .utf8) == "old-app")
        #expect(try String(contentsOf: data.appendingPathComponent("value"), encoding: .utf8) == "old-data")
        #expect(try String(contentsOf: candidate.appendingPathComponent("value"), encoding: .utf8) == "new-app")
        #expect(try String(contentsOf: transaction.dataBackup.appendingPathComponent("value"), encoding: .utf8) == "new-data")
    }

    /// 悬空/外部/循环链接提前拒绝；合法内部链接应走到后续签名检查。
    @Test(arguments: ["dangling-external", "dangling-internal", "cycle", "internal", "framework", "external"])
    func bundleLinkBoundary(_ kind: String) throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("LocalClip.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": UpdatePackage.bundleIdentifier, "CFBundleExecutable": "LocalClip", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "100", "LSMinimumSystemVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        // 使用 POSIX 真实路径，避免 Foundation 对 /private 别名的处理让错误用例假通过。
        let actualApp = URL(fileURLWithPath: try #require(UpdateLocations.realPath(app)))
        let link = actualApp.appendingPathComponent("Contents/Resources/link")
        let target: URL
        switch kind {
        case "internal": target = actualApp.appendingPathComponent("Contents/Info.plist")
        case "framework":
            let versions = actualApp.appendingPathComponent("Contents/Frameworks/Example.framework/Versions")
            try fm.createDirectory(at: versions.appendingPathComponent("A"), withIntermediateDirectories: true)
            try Data("framework".utf8).write(to: versions.appendingPathComponent("A/Example"))
            try fm.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "A")
            try fm.createSymbolicLink(atPath: versions.deletingLastPathComponent().appendingPathComponent("Example").path, withDestinationPath: "Versions/Current/Example")
            target = versions.deletingLastPathComponent().appendingPathComponent("Example")
        case "dangling-internal": target = actualApp.appendingPathComponent("Contents/missing")
        case "cycle": target = link
        case "external": target = URL(fileURLWithPath: try #require(UpdateLocations.realPath(root))).appendingPathComponent("existing"); try Data("outside".utf8).write(to: target)
        default: target = root.appendingPathComponent("missing")
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let manifest = UpdateManifest(version: "1.0", build: 100, minimumSystemVersion: "15.0", architectures: ["arm64"], archive: "unused", size: 1, sha256: "unused")
        do { try UpdatePackage.validateBundle(actualApp, manifest: manifest); Issue.record("未签名测试包不应通过") }
        catch { #expect(error.localizedDescription == (["internal", "framework"].contains(kind) ? "更新校验失败：codesign" : "更新应用包含外部链接")) }
    }
}
