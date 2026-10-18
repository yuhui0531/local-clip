// 剩余comments的输出、预览和恢复边界；仅合成数据与临时目录，by AI.Coding。
import Foundation
import Darwin
import Testing
import LocalClipCore
@testable import LocalClipMac
@testable import LocalClipUpdateKit

struct CommentRemainingTests {
    /// 批量判定必须与逐项旧入口完全一致，覆盖换行、JSON片段、颜色、编码和空值。
    @Test func bulkTransformAvailabilityPreservesEveryAction() {
        let values = ["", "hello", "\n", " a\r\n b\r\n", "1. one\n2. two", "$ echo hi\n% ls", "{\"a\":1}", "true", "123", "\"abc\"", "[1,", "#FFF", "rgba(1,2,3,0.5)", "hsl(360,100%,50%)", "i++", "SGVsbG8=", "中文👩🏽‍💻\n中", "2025-01-01T00:00:00Z"]
        for text in values { #expect(TextTransform.applicableTransforms(text) == Set(TextTransform.allCases.filter { $0.isApplicable(text) })) }
        #expect(TextTransform.applicableTransforms(String(repeating: "x", count: TextTransform.byteLimit + 1)).isEmpty)
    }
    /// 纯文本输入未超预算时，不应因额外生成的富文本而失败；小输出仍保留既有富文本。
    @Test func generatedRichTextDoesNotRejectLargePlainMerge() throws {
        func payload(_ text: String) -> ClipboardPayload { .init([.init([.init(SupportedType.string, Data(text.utf8))], plainText: text)]) }
        let text = String(repeating: "a", count: 9 * 1_048_576)
        let merged = try OutputComposer.combine([payload(text), payload(text)], format: .original)
        #expect(merged.plainText == text + "\n" + text)
        #expect(merged.items[0].representations.map(\.type) == [SupportedType.string])
        let small = try OutputComposer.combine([payload("one"), payload("two")], format: .original)
        #expect(small.items[0].representations.contains { $0.type == SupportedType.rtf })
        // 带真实富文本的输入不得用丢格式方式绕过预算。
        let rich = ClipboardPayload([.init([.init(SupportedType.string, Data(text.utf8)), .init(SupportedType.html, Data("<b>rich</b>".utf8))], plainText: text)])
        let larger = payload(String(repeating: "b", count: 20 * 1_048_576))
        #expect(throws: OutputBudget.exceeded) { try OutputComposer.combine([rich, larger], format: .original) }
    }
    /// 后续目录不应阻止首个文件预览；首项不可读仍拒绝，引用顺序完整保留。
    @Test func previewTracksDisplayedFileInMixedReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("first.txt"), folder = root.appendingPathComponent("folder")
        try Data("first".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let version = try #require(FileReferencePreviewVersion.read([file, folder]))
        #expect(version.references == [file, folder] && version.isCurrent())
        #expect(FileReferencePreviewVersion.read([folder, file]) == nil)
        try Data("changed".utf8).write(to: file)
        #expect(!version.isCurrent())
    }
    /// 仅可信回执与两代应用身份一致时收敛成功；不删主数据与最近成功快照。
    @Test(arguments: [UpdatePhase.awaitingReceipt, .swapping])
    func confirmedStartupCompletesAbandonedSession(_ phase: UpdatePhase) throws {
        let fixture = try UpdateJanitorTests.Fixture(); defer { fixture.cleanUp() }
        let record = try fixture.session(phase: phase, installed: 101, candidate: 100)
        let download = URL(fileURLWithPath: try #require(record.download))
        try Data("101".utf8).write(to: download.appendingPathComponent("startup-ok"))
        let report = UpdateJanitor.run(fixture.locations, migrate: false)
        #expect(fixture.record(record.id)?.phase == .succeeded)
        #expect(!fixture.exists(fixture.workspace(record)) && !fixture.exists(download))
        #expect(fixture.exists(fixture.backup(record).appendingPathComponent("data/history")))
        #expect(report.failures.isEmpty)
        try fixture.assertUserDataIntact()
    }
    /// 不完整/矛盾/外链证据和持久化失败均保留旧程序、下载和数据快照。
    @Test(arguments: ["missing", "wrong", "extra", "symlink", "fifo", "candidate-info-fifo", "candidate", "installed", "excluded", "save-failure", "workspace-link", "candidate-dir-link", "candidate-app-link", "target-link", "info-link", "download-link"])
    func uncertainStartupKeepsRecovery(_ reason: String) throws {
        let fixture = try UpdateJanitorTests.Fixture(); defer { fixture.cleanUp() }
        let record = try fixture.session(phase: .awaitingReceipt, installed: reason == "installed" ? 102 : 101, candidate: reason == "candidate" ? 99 : 100)
        let download = URL(fileURLWithPath: try #require(record.download)), receipt = download.appendingPathComponent("startup-ok")
        if reason == "symlink" {
            let other = fixture.root.appendingPathComponent("other-receipt")
            try Data("101".utf8).write(to: other)
            try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: other)
        } else if reason != "missing" { try Data((reason == "wrong" ? "100" : reason == "extra" ? "101\n" : "101").utf8).write(to: receipt) }
        if reason == "fifo" {
            try FileManager.default.removeItem(at: receipt)
            #expect(mkfifo(receipt.path, mode_t(0o600)) == 0)
        }
        if reason == "candidate-info-fifo" {
            let info = fixture.workspace(record).appendingPathComponent("candidate/LocalClip.app/Contents/Info.plist")
            try FileManager.default.removeItem(at: info)
            #expect(mkfifo(info.path, mode_t(0o600)) == 0)
        }
        if reason == "download-link" {
            let other = fixture.locations.updatesCache.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: download, to: other)
            try FileManager.default.createSymbolicLink(at: download, withDestinationURL: other)
        }
        let links = ["workspace-link": fixture.workspace(record), "candidate-dir-link": fixture.workspace(record).appendingPathComponent("candidate"),
                     "candidate-app-link": fixture.workspace(record).appendingPathComponent("candidate/LocalClip.app"),
                     "target-link": fixture.target, "info-link": fixture.workspace(record).appendingPathComponent("candidate/LocalClip.app/Contents/Info.plist")]
        if let path = links[reason] {
            let outside = fixture.root.appendingPathComponent("moved-object")
            try FileManager.default.moveItem(at: path, to: outside)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        }
        if reason == "save-failure" {
            let lock = UpdateSessionLock(id: record.id, locations: fixture.locations)
            #expect(lock.tryAcquire()); lock.release()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.locations.sessions.path)
        }
        _ = UpdateJanitor.run(fixture.locations, excludedDownloads: reason == "excluded" ? [download.path] : [], migrate: false)
        #expect(fixture.record(record.id)?.phase == .awaitingReceipt)
        #expect(fixture.exists(fixture.workspace(record)) && fixture.exists(download))
        #expect(fixture.exists(fixture.backup(record).appendingPathComponent("data/history")))
        try fixture.assertUserDataIntact()
    }
}
