// 审查修复前后同生成器服务层计时，不宣称界面端到端验收，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct ReviewPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_BENCHMARK"] == "1"))
    func coldWarmAndPostQuotaSearch() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-store")
        _ = try BenchmarkGenerator.seed(root, output: output)
        let store = try HistoryStore(location: root)
        let queries = ["需求", "代", "foo_bar", "50%", "a->b", "?a=1&b=2", "END-9999", "fixture-1234", "missing-literal", "The local"]
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var warm: [Double] = [], cold: [Double] = [], ingest: [Double] = [], thumbnails: [Double] = [], pressure: [Double] = [], postPressure: [Double] = []
        for index in 0..<200 {
            let start = ContinuousClock.now; _ = try await store.search(.init(queries[index % queries.count])); warm.append(milliseconds(start))
        }
        for index in 0..<40 {
            let start = ContinuousClock.now
            guard case .inserted = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("review-cold-\(index)".utf8))])])), at: SystemClock().now()) else { Issue.record("capture not inserted"); return }
            ingest.append(milliseconds(start))
            let searchStart = ContinuousClock.now; _ = try await store.search(.init(queries[index % queries.count])); cold.append(milliseconds(searchStart))
        }
        let metadata = try await store.metadata(id: "benchmark-10000", at: SystemClock().now())
        for index in 0..<20 {
            let start = ContinuousClock.now
            #expect(try await store.cacheThumbnail(id: metadata.summary.id, revision: metadata.revision, data: Data(repeating: UInt8(index), count: 80_000)))
            thumbnails.append(milliseconds(start))
        }
        let usage = try await store.usage(), quota = usage.measuredTotal + 12 * MiB
        let preview = try await store.preview(.quota(quota)); _ = try await store.apply(preview.token)
        for index in 0..<3 {
            let start = ContinuousClock.now
            let revision = try await store.settings().revision
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data(repeating: UInt8(80 + index), count: Int(8 * MiB)))])]), revision: revision), at: SystemClock().now())
            pressure.append(milliseconds(start))
        }
        for index in 0..<20 {
            let revision = try await store.settings().revision
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("post-pressure-\(index)".utf8))])]), revision: revision), at: SystemClock().now())
            let start = ContinuousClock.now; _ = try await store.search(.init(queries[index % queries.count])); postPressure.append(milliseconds(start))
        }
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        let texts = try db.scalarInt("SELECT COUNT(*) FROM clips WHERE kind='text'"), indexed = try db.scalarInt("SELECT COUNT(*) FROM text_content")
        #expect(indexed == texts); try db.close()
        try BenchmarkGenerator.write(["boundary": "HistoryStore call to return; excludes input, debounce, polling and draw", "warm": BenchmarkGenerator.metrics(warm), "afterCapture": BenchmarkGenerator.metrics(cold), "ingest": BenchmarkGenerator.metrics(ingest), "thumbnail": BenchmarkGenerator.metrics(thumbnails), "quotaWrites": BenchmarkGenerator.metrics(pressure), "postPressure": BenchmarkGenerator.metrics(postPressure), "survivingTextClips": texts, "indexRows": indexed], to: output.appendingPathComponent("results.json"))
    }
}
