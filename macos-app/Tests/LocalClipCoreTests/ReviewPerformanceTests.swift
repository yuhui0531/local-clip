// 审查修复前后同生成器服务层计时，不宣称界面端到端验收，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct ReviewPerformanceTests {
    /// 延迟至少500ms测捕获后的首个字面查询，并保留提交、冷首查及热查的完整样本，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_R02_WARMUP_BENCHMARK"] == "1"))
    func pageCacheWarmupBenchmark() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-store")
        let manifest = try BenchmarkGenerator.seed(root, output: output)
        let store = try HistoryStore(location: root)
        let queries = ["需求", "代", "foo_bar", "50%", "a->b", "?a=1&b=2", "END-9999", "fixture-1234", "missing-literal", "The local"]
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var warm: [Double] = [], firstAfterCapture: [Double] = [], ingest: [Double] = []
        for _ in 0..<10 { _ = try await store.search(.init("The local")) }
        for index in 0..<30 {
            let query = queries[index % queries.count]
            let snapshot = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.string, Data("r02-reprobe-\(index) delayed search fixture".utf8))])]), revision: try await store.settings().revision)
            let ingestStart = ContinuousClock.now
            guard case .inserted = try await store.ingest(snapshot, at: SystemClock().now()) else { Issue.record("capture not inserted"); return }
            ingest.append(milliseconds(ingestStart))
            try await Task.sleep(for: .milliseconds(500))
            let searchStart = ContinuousClock.now
            _ = try await store.search(.init(query))
            firstAfterCapture.append(milliseconds(searchStart))
        }
        for index in 0..<100 {
            let searchStart = ContinuousClock.now
            _ = try await store.search(.init(queries[index % queries.count]))
            warm.append(milliseconds(searchStart))
        }
        let verified = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        let integrity = try verified.scalarText("PRAGMA integrity_check")
        let foreignKeys = try verified.rows("PRAGMA foreign_key_check")
        try verified.close()
        #expect(integrity == "ok"); #expect(foreignKeys.isEmpty)
        try BenchmarkGenerator.write([
            "build": "Release", "fixture": manifest["generator"] ?? "", "seed": manifest["seed"] ?? "",
            "boundary": "HistoryStore service calls; each first literal search starts at least 500ms after its successful capture",
            "queries": queries, "postCaptureDelayMs": 500, "firstLiteralSearchAfterIngest": BenchmarkGenerator.metrics(firstAfterCapture),
            "warmSearch": BenchmarkGenerator.metrics(warm), "ingestCommit": BenchmarkGenerator.metrics(ingest),
            "integrityCheck": integrity, "foreignKeyViolations": foreignKeys.count
        ], to: output.appendingPathComponent("page-cache-warmup-results.json"))
    }
    /// 固定v2数据集上测已预热前缀扩展的服务延迟，原样保留每个样本，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_SEARCH_NARROW_BENCHMARK"] == "1"))
    func warmExtendedLiteralSearch() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-store")
        let manifest = try BenchmarkGenerator.seed(root, output: output)
        let store = try HistoryStore(location: root)
        let pairs = [
            ("需求", "需求，"), ("代", "代码"), ("foo_bar", "foo_bar ="), ("50%", "50%;"),
            ("a->b", "a->b;"), ("?a=1&b=2", "?a=1&b=2#section"), ("END-9999", "END-9999x"),
            ("fixture-1234", "fixture-1234 https://"), ("missing-literal", "missing-literalx"),
            ("The local", "The local clipboard")
        ]
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now)
            return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        var samples: [Double] = []
        for index in 0..<100 {
            let (prefix, extended) = pairs[index % pairs.count]
            _ = try await store.search(.init(prefix))
            let started = ContinuousClock.now
            _ = try await store.search(.init(extended))
            samples.append(milliseconds(started))
        }
        let sorted = samples.sorted()
        try BenchmarkGenerator.write([
            "build": "Release", "fixture": manifest["generator"] ?? "", "seed": manifest["seed"] ?? "",
            "boundary": "HistoryStore.search return; each measured extended literal follows its prefix search",
            "queries": pairs.map { ["prefix": $0.0, "extended": $0.1] },
            "samplesMs": samples, "n": samples.count,
            "p95Ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], "meanMs": samples.reduce(0, +) / Double(samples.count),
            "maxMs": sorted.last!
        ], to: output.appendingPathComponent("extended-search-results.json"))
    }
    /// 固定真实编码图像给隔离GUI包，生成成本不算粘贴延迟，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_GUI_FIXTURES"] == "1"))
    func prepareGUIFixtures() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try BenchmarkGenerator.seed(output.appendingPathComponent("fixture-store"), output: output)
        var manifest: [[String:Any]] = []
        for index in 0..<20 {
            let (type,data) = try BenchmarkGenerator.image(200+index)
            #expect(type == SupportedType.png)
            try data.write(to: output.appendingPathComponent("image-\(index).png"))
            manifest.append(["index":index,"bytes":data.count,"sha256":ContentFingerprint.hash(data)])
        }
        try BenchmarkGenerator.write(manifest, to: output.appendingPathComponent("new-images.json"))
    }
    /// 同记录数、四种正文体积测量小写入；初始化/校验不混入提交样本，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_SCALING_BENCHMARK"] == "1"))
    func writeScaling() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var curves: [[String: Any]] = []
        for target in [10, 100, 226, 480] {
            let root = output.appendingPathComponent("scale-\(target)")
            let strategy = try CommitStrategy(root: root)
            var settings = SettingsSnapshot(); settings.quotaBytes = 1024 * MiB
            try strategy.initialize { try Schema.create($0, settings: settings) }
            let db = try SQLiteConnection(strategy.databaseURL); try db.configure(); try db.exec("BEGIN IMMEDIATE")
            for index in 0..<16 {
                let data = Data(repeating: UInt8(index), count: target * 1_048_576 / 16)
                let payload = ClipboardPayload([.init([.init(SupportedType.png, data)])]), digest = ContentFingerprint.hash(data), id = "scale-\(index)"
                try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceBundleID,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,?, ?,?,?,?,?,?)", [.text(id), .text(payload.fingerprint), .integer(SystemClock().now()), .integer(SystemClock().now()), .integer(1), .text("image"), .integer(0), .null, .text("unknown"), .text("unknown"), .text("")])
                try db.run("INSERT INTO items VALUES(?,?,?)", [.text(id), .integer(0), .text("[]")])
                try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(data.count)), .blob(data)])
                try db.run("INSERT INTO representations VALUES(?,?,?,?)", [.text(id), .integer(0), .text(SupportedType.png), .text(digest)])
            }
            try db.exec("COMMIT"); try db.close()
            let store = try HistoryStore(location: root), bytes = try await store.usage().measuredTotal
            var inserts: [Double] = [], preferences: [Double] = [], dedup: [Double] = []
            func elapsed(_ start: ContinuousClock.Instant) -> Double { let d = start.duration(to: .now); return Double(d.components.seconds)*1000 + Double(d.components.attoseconds)/1e15 }
            for index in 0..<40 {
                let snapshot = ClipboardSnapshot(payload: fixture("scale-write-\(index)").payload, revision: try await store.settings().revision)
                let start = ContinuousClock.now; let inserted = try await store.ingest(snapshot, at: SystemClock().now()); inserts.append(elapsed(start))
                guard case .inserted = inserted else { Issue.record("scaling capture not inserted"); return }
                var value = try await store.settings(); value.captureSounds.toggle()
                let preferenceStart = ContinuousClock.now; _ = try await store.updateCaptureSettings(value); preferences.append(elapsed(preferenceStart))
                let revision = try await store.settings().revision
                let duplicateStart = ContinuousClock.now; let duplicate = try await store.ingest(.init(payload: snapshot.payload, revision: revision), at: SystemClock().now()); dedup.append(elapsed(duplicateStart))
                guard case .deduplicated = duplicate else { Issue.record("scaling duplicate not committed"); return }
            }
            let verified = try SQLiteConnection(strategy.databaseURL, readonly: true)
            #expect(try verified.scalarText("PRAGMA integrity_check") == "ok"); #expect(try verified.rows("PRAGMA foreign_key_check").isEmpty); try verified.close()
            curves.append(["targetMiB":target,"initialBytes":bytes,"textInsert":BenchmarkGenerator.metrics(inserts),"settings":BenchmarkGenerator.metrics(preferences),"dedup":BenchmarkGenerator.metrics(dedup)])
        }
        try BenchmarkGenerator.write(["build":"Release", "boundary":"HistoryStore call to return, in-place SQLite transaction / rollback journal / fullfsync", "fixture":"16 equal-sized synthetic opaque image blobs; isolates storage size, not image decoding", "curves":curves], to: output.appendingPathComponent("scaling.json"))
    }
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
