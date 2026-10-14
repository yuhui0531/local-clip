// 本次审查修复前后的同机基准；只使用临时库与合成内容，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ReviewRemediationPerformanceTests {
    /// 保存原始样本，不把服务计时称为外部应用端到端验收。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REMEDIATION_PERF"] == "1"))
    func storageRichTextAndImageDrag() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REMEDIATION_OUTPUT"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        func ms(_ begin: ContinuousClock.Instant) -> Double {
            let value = begin.duration(to: .now)
            return Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15
        }
        var writes: [Double] = [], pages: [Double] = [], rich: [Double] = [], drag: [Double] = []
        for index in 0..<220 {
            let begin = ContinuousClock.now
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("review-perf-\(index)".utf8))])])), at: SystemClock().now())
            // 预热轻量缓存，覆盖真实浏览后提交时的缓存维护路径。
            let page = try await store.search(.init())
            if let id = page.items.first?.id { _ = try await store.textCharacterCount(id: id, at: SystemClock().now()) }
            if index >= 20 { writes.append(ms(begin)) }
        }
        for _ in 0..<200 { let begin = ContinuousClock.now; _ = try await store.search(.init()); pages.append(ms(begin)) }
        let html = String(repeating: "<a href='https://example.invalid' style='font-size: 14px; color: #112233'>text</a>", count: 200)
        for _ in 0..<100 { let begin = ContinuousClock.now; _ = RichContent.attributed(.init([.init(SupportedType.html, Data(html.utf8))])); rich.append(ms(begin)) }
        var ids: [ClipID] = []
        for index in 0..<3 {
            let data = Data(repeating: UInt8(index + 1), count: 10 * Int(MiB))
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, data)])])), at: SystemClock().now()) else { throw StoreError.notFound }
            ids.append(id)
        }
        for _ in 0..<10 {
            try await store.clearDragFiles()
            let begin = ContinuousClock.now
            _ = try await ContentExportProvider.writers(ids: ids, store: store, token: "perf", register: { _ in })
            drag.append(ms(begin))
        }
        func metrics(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            return ["samplesMs": values, "meanMs": values.reduce(0,+) / Double(values.count), "p95Ms": sorted[Int(ceil(Double(values.count) * 0.95)) - 1]]
        }
        let report: [String: Any] = ["ingestSearchCount": metrics(writes), "firstPage": metrics(pages), "html200Tags": metrics(rich), "drag3x10MiB": metrics(drag)]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }
}
