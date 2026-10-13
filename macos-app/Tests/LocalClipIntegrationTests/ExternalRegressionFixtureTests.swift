import AppKit
import ImageIO
import Testing
import LocalClipCore

/// Opt-in fixture preparation only. Does not launch apps, send UI events or access the system clipboard.
struct ExternalRegressionFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_EXTERNAL_FIXTURES"] != nil))
    func prepareExternalRegressionFixtures() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LOCALCLIP_EXTERNAL_FIXTURES"])
        let output = URL(fileURLWithPath: path).standardizedFileURL
        #expect(output.path.contains("/macos-app/evidence/"))
        guard output.path.contains("/macos-app/evidence/") else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func encoded(_ type: String, pages: Int) throws -> Data {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, pages, nil))
            for page in 0..<pages {
                let context = try #require(CGContext(data: nil, width: 512, height: 384, bitsPerComponent: 8,
                                                    bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(),
                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(page == 0 ? CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1) : CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
                context.setFillColor(page == 0 ? CGColor(red: 1, green: 0.7, blue: 0.1, alpha: 1) : CGColor(red: 0.8, green: 0.15, blue: 0.3, alpha: 1))
                context.fill(CGRect(x: 40, y: 40, width: page == 0 ? 180 : 320, height: 180))
                let image = try #require(context.makeImage())
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFImageDescription: "LocalClip external regression page \(page + 1)",
                    kCGImagePropertyTIFFArtist: "Synthetic regression fixture"
                ]] as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let png = try encoded(SupportedType.png, pages: 1)
        let tiff = try encoded(SupportedType.tiff, pages: 1)
        let multipage = try encoded(SupportedType.tiff, pages: 2)
        for (name, data) in [("source.png", png), ("source.tiff", tiff), ("source-multipage.tiff", multipage)] {
            try data.write(to: output.appendingPathComponent(name))
        }
        var settings = SettingsSnapshot(); settings.autoCheckUpdates = false
        let store = try HistoryStore(location: output.appendingPathComponent("working-store"), initialSettings: settings)
        let cases: [(String, [Representation])] = [
            ("E2E PNG only", [.init(SupportedType.png, png)]),
            ("E2E TIFF only", [.init(SupportedType.tiff, tiff)]),
            ("E2E TIFF two pages", [.init(SupportedType.tiff, multipage)]),
            ("E2E PNG plus two-page TIFF", [.init(SupportedType.png, png), .init(SupportedType.tiff, multipage)]),
            ("E2E invalid PNG plus TIFF", [.init(SupportedType.png, Data("invalid PNG fixture".utf8)), .init(SupportedType.tiff, multipage)]),
            ("E2E text shortcut", [.init(SupportedType.string, Data("LOCALCLIP-E2E-TEXT-20261013".utf8))]),
            ("E2E rich text", [.init(SupportedType.rtf, Data("{\\rtf1\\ansi LOCALCLIP-\\b BOLD\\b0 -E2E}".utf8))])
        ]
        var manifest: [[String: Any]] = []
        for (index, entry) in cases.enumerated() {
            let payload = ClipboardPayload([.init(entry.1)])
            let result = try await store.ingest(.init(payload: payload), at: SystemClock().now() + Int64(index))
            let id: ClipID
            switch result {
            case .inserted(let value), .deduplicated(let value): id = value
            case .skipped: Issue.record("Fixture rejected"); continue
            }
            try await store.renameClip(id: id, title: entry.0)
            manifest.append(["id": id, "title": entry.0, "fingerprint": payload.fingerprint,
                             "representations": entry.1.map { ["type": $0.type, "bytes": $0.data.count, "sha256": ContentFingerprint.hash($0.data)] }])
        }
        // 入库后再提交（暂停期间存储拒绝入库，重新生成需先删除working-store）：外部验收使用系统剪贴板，
        // 30天定时暂停跨启动保留，避免捕获用户内容；⌃⌥⌘V避开正式版⌥⌘V；卡片顺序固定供数字键验证。
        settings = try await store.settings()
        settings.pauseUntil = SystemClock().now() + 30 * 24 * 3_600_000
        settings.shortcut = .init(keyCode: 9, modifiers: 6400)
        settings.moveUsedToFront = false
        _ = try await store.updateCaptureSettings(settings)
        if try await store.categories().isEmpty { _ = try await store.createCategory(name: "E2E Drop", colorHex: "34C759") }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("fixture-manifest.json"))
        #expect(manifest.count == cases.count)
    }
}
