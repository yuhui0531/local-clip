// LC-V01原生验收：只生成合成图片与全文，使用独立库及私有板，by AI.Coding。
import AppKit
import ImageIO
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct LargeImageNativeFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_LARGE_NATIVE_FIXTURE"] == "1"))
    func prepare() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_NATIVE_OUTPUT"]))
        let root = output.appendingPathComponent("working-store")
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var settings = SettingsSnapshot()
        settings.autoCheckUpdates = false; settings.timingEnabled = true
        settings.shortcut = .init(keyCode: 9, modifiers: 6400)
        let store = try HistoryStore(location: root, initialSettings: settings, extractor: ContentDecoder.extract)
        var manifest: [[String: Any]] = []
        let now = SystemClock().now()
        for size in [100, 100 * 1024, 300 * 1024, 1024 * 1024] {
            let prefix = "LC-F01 \(size) BEGIN\n", suffix = "\nLC-F01 \(size) END"
            let text = prefix + String(repeating: "Log entry 中文🙂 0123456789\n", count: max(1, size / 32)) + suffix
            let bytes = Data(text.utf8), name = "LC-F01-\(size).txt"
            let id = try await insert(.init([.init([.init(SupportedType.string, bytes)])]), title: name, store: store, at: now)
            try bytes.write(to: output.appendingPathComponent(name))
            manifest.append(["kind": "text", "id": id, "name": name, "bytes": bytes.count, "sha256": ContentFingerprint.hash(bytes)])
        }
        for index in 1...3 {
            let name = "LC-V01-LARGE-\(index)", bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 2458, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 3200 * 4, bitsPerPixel: 32))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 3200, height: 2458).fill()
            (name as NSString).draw(at: .init(x: 100, y: 1200), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 150), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            let image = try #require(bitmap.cgImage), bytes = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(bytes, SupportedType.tiff as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            let data = bytes as Data
            let id = try await insert(.init([.init([.init(SupportedType.tiff, data)])]), title: name, store: store, at: now + Int64(index))
            try data.write(to: output.appendingPathComponent(name + ".tiff"))
            manifest.append(["kind": "image", "id": id, "name": name + ".tiff", "type": SupportedType.tiff, "bytes": data.count, "sha256": ContentFingerprint.hash(data)])
        }
        _ = try await store.createCategory(name: "LC-V01 internal", colorHex: "34C759")
        settings = try await store.settings(); settings.pauseUntil = now + 7 * 24 * 60 * 60 * 1000
        _ = try await store.updateCaptureSettings(settings)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("fixture-manifest.json"))
        #expect(try await store.integrityCheck())
    }
    private func insert(_ payload: ClipboardPayload, title: String, store: HistoryStore, at: Instant) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: at) else { throw StoreError.notFound }
        try await store.renameClip(id: id, title: title)
        return id
    }
}
