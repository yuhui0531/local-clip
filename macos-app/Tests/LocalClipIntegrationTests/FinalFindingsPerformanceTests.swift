// LC-F01/LC-V01：保存有界高度计算与原生私有粘贴板索取的阶段计时，不冒充物理拖放验收，by AI.Coding。
import AppKit
import ImageIO
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct FinalFindingsPerformanceTests {
    /// 临时库、真实30MiB TIFF与私有板；新路径和已有路径分开测量，系统文件缓存未强制清空。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_FINAL_FINDINGS_PERF"] == "1"))
    func previewAndLargeImageRequests() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_FINAL_FINDINGS_OUTPUT"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        // 在同步请求边界记录实际线程，不能把actor隔离标签当作原生回调线程证据。
        func requestingMainThread() -> Bool { Thread.isMainThread }
        var heights: [[String: Any]] = []
        for size in [100, 100 * 1024, 300 * 1024, 1024 * 1024] {
            let content = NSAttributedString(string: String(repeating: "x", count: size), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = ContinuousClock.now
                _ = InspectorPreviewLayout.height(for: content)
                samples.append(ms(start))
            }
            heights.append(["utf16Length": size, "samplesMs": samples])
        }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        var ids: [ClipID] = [], sizes: [Int] = [], hashes: [String] = []
        // 3200x2458x4约30MiB，TIFF不压缩并使用不同元数据以保留三个独立记录。
        let png = try ImageFixtures.image(width: 3200, height: 2458)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        for index in 0..<3 {
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, SupportedType.tiff as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1, kCGImagePropertyTIFFImageDescription: "fixture-\(index)"]] as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            sizes.append(data.length); hashes.append(ContentFingerprint.hash(data as Data))
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.tiff, data as Data)])])), at: now + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        // LC-V01拆分只读加载/校验、重复哈希和原子写盘，定位同步回调成本。
        var stages: [[String: Any]] = []
        let access = try await store.exportAccess(id: ids[0])
        for index in 0..<5 {
            let begin = ContinuousClock.now
            let data = try access.itemData(index: 0, type: SupportedType.tiff)
            let readMs = ms(begin), hashBegin = ContinuousClock.now
            _ = ContentFingerprint.hash(data)
            let hashMs = ms(hashBegin), writeBegin = ContinuousClock.now
            let file = root.appendingPathComponent("stage-\(index).tiff")
            try data.write(to: file, options: .atomic)
            let writeMs = ms(writeBegin)
            try FileManager.default.removeItem(at: file)
            stages.append(["readAndValidateMs": readMs, "duplicateHashMs": hashMs, "atomicWriteMs": writeMs])
        }
        var requests: [[String: Any]] = []
        for round in 0..<3 {
            // 第一轮新建，后续轮复用；取消清理不在计时窗口内。
            let start = ContinuousClock.now
            let writers = try await ContentExportProvider.writers(ids: ids, store: store, token: "benchmark", register: { _ in })
            let prepareMs = ms(start)
            let board = NSPasteboard(name: .init("local.localclip.large-receiver." + UUID().uuidString))
            defer { board.releaseGlobally() }
            try #require(board.writeObjects(writers))
            try ContentExportProvider.installImageDataProviders(writers, on: board)
            let items = try #require(board.pasteboardItems)
            var samples: [Double] = [], warm: [Double] = []
            for (index, item) in items.enumerated() {
                let begin = ContinuousClock.now
                let received = item.string(forType: .fileURL)
                samples.append(ms(begin))
                let url = try #require(received.flatMap(URL.init(string:)))
                #expect(try ContentFingerprint.hash(Data(contentsOf: url)) == hashes[index])
                let repeatStart = ContinuousClock.now
                #expect(item.string(forType: .fileURL) == received)
                warm.append(ms(repeatStart))
            }
            requests.append(["round": round, "pathState": round == 0 ? "new" : "existing", "prepareMs": prepareMs, "fileURLRequestMs": samples, "sameItemRepeatMs": warm, "requestingThreadIsMain": requestingMainThread()])
        }
        #expect(try await store.integrityCheck())
        let report: [String: Any] = ["previewHeight": heights, "imageBytes": sizes, "imageSHA256": hashes, "requests": requests, "stages": stages,
            "scope": "Private native pasteboard requests in-process. No physical hover/drop, cross-process receiver, cold OS cache or installed-app claim."]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
