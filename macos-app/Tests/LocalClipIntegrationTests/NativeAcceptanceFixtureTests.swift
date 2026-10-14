// 原生验收使用可识别合成材料；只写显式指定的独立目录，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct NativeAcceptanceFixtureTests {
    /// LC-R01真实接收验收：每种原图格式独立留存哈希，禁止使用生产库，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_DEFERRED_FIXTURE"] == "1"))
    func prepareDeferredImageDragFixture() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_NATIVE_OUTPUT"]))
        let root = output.appendingPathComponent("working-store")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        var settings = SettingsSnapshot()
        settings.autoCheckUpdates = false; settings.timingEnabled = true
        settings.shortcut = .init(keyCode: 9, modifiers: 6400)
        let store = try HistoryStore(location: root, initialSettings: settings, extractor: ContentDecoder.extract)
        var manifest: [[String: Any]] = []
        for (offset, format) in ["png", "jpeg", "tiff"].enumerated() {
            let label = "LC-R01-" + format.uppercased()
            let image = NSImage(size: .init(width: 640, height: 180))
            image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 180).fill()
            (label as NSString).draw(at: .init(x: 30, y: 75), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 38), .foregroundColor: NSColor.black]); image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let rep = try #require(NSBitmapImageRep(data: tiff))
            let type = format == "png" ? SupportedType.png : format == "jpeg" ? SupportedType.jpeg : SupportedType.tiff
            let bytes = format == "tiff" ? tiff : try #require(rep.representation(using: format == "png" ? .png : .jpeg, properties: [:]))
            let payload = ClipboardPayload([.init([.init(type, bytes)])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now() + Int64(offset)) else { throw StoreError.notFound }
            try await store.renameClip(id: id, title: label)
            let name = label + (format == "jpeg" ? ".jpg" : "." + format)
            try bytes.write(to: output.appendingPathComponent(name))
            manifest.append(["id": id, "name": name, "type": type, "bytes": bytes.count, "sha256": ContentFingerprint.hash(bytes), "fingerprint": payload.fingerprint])
        }
        _ = try await store.createCategory(name: "LC-R01 internal drop", colorHex: "34C759")
        settings = try await store.settings(); settings.pauseUntil = SystemClock().now() + 7 * 24 * 60 * 60 * 1000
        _ = try await store.updateCaptureSettings(settings)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("drag-fixture-manifest.json"))
        #expect(try await store.integrityCheck())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NATIVE_FIXTURE"] == "1"))
    func prepareNativeAcceptanceFixture() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOCALCLIP_NATIVE_OUTPUT"])
        let output = URL(fileURLWithPath: path), root = output.appendingPathComponent("working-store")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = SettingsSnapshot()
        settings.autoCheckUpdates = false; settings.timingEnabled = true
        settings.shortcut = .init(keyCode: 9, modifiers: 6400)
        let store = try HistoryStore(location: root, initialSettings: settings, extractor: ContentDecoder.extract)
        let plain = "LC-NATIVE-20261014-PLAIN · 中文🙂\nSecond line: 50% foo_bar"
        let file = output.appendingPathComponent("LC-NATIVE-FILE.txt")
        try Data("LC-NATIVE-20261014-FILE\nSynthetic reference only.\n".utf8).write(to: file)
        let rich = NSAttributedString(string: "LC-NATIVE-20261014-RICH", attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.systemRed])
        let rtf = try #require(rich.rtf(from: .init(location: 0, length: rich.length), documentAttributes: [:]))
        let image = NSImage(size: .init(width: 900, height: 240))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        ("LC NATIVE HIDDEN OCR 20261014" as NSString).draw(at: .init(x: 30, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black]); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("LC-NATIVE-IMAGE.png"))
        let fixtures: [(String, ClipboardPayload)] = [
            ("file", .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])),
            ("image", .init([.init([.init(SupportedType.png, png), .init(SupportedType.tiff, tiff)])])),
            ("rich", .init([.init([.init(SupportedType.rtf, rtf), .init(SupportedType.string, Data(rich.string.utf8))])])),
            ("plain", .init([.init([.init(SupportedType.string, Data(plain.utf8))])]))
        ]
        var manifest: [[String: Any]] = []
        for (offset, fixture) in fixtures.enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: fixture.1), at: SystemClock().now() + Int64(offset)) else { throw StoreError.notFound }
            manifest.append(["kind": fixture.0, "id": id, "fingerprint": fixture.1.fingerprint, "text": fixture.1.plainText ?? ""])
        }
        // AppDelegate可恢复会话开关，未来的定时暂停仍阻止读取系统剪贴板正文。
        settings = try await store.settings(); settings.pauseUntil = SystemClock().now() + 7 * 24 * 60 * 60 * 1000
        _ = try await store.updateCaptureSettings(settings)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("fixture-manifest.json"))
        try Data(plain.utf8).write(to: output.appendingPathComponent("expected-plain.txt"))
    }
}
