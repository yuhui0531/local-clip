// 合成大库的服务/模型发布与主线程响应基准；不展示窗口、不接触用户库或系统剪贴板，by AI.Coding。
import Foundation
import Darwin
import CryptoKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct CommentPerformanceTests {
    private struct Manifest: Codable, Sendable {
        let generator: String
        let rows: Int
        let payloadBytes: Int64
        let datasetSHA256: String
        let databaseBytes: Int64
        let createdAtMs: Int64
    }
    private struct Phase: Codable {
        let name: String
        let durationMs: Double
        let cpuSeconds: Double
        let peakResidentBytes: Int64
        let heartbeatIntervalMs: Double
        let heartbeatGapsMs: [Double]
        let maximumHeartbeatGapMs: Double
        let heartbeatGapsOver50Ms: Int
    }
    private struct Report: Codable {
        let scope: String
        let fixture: Manifest
        let fixturePath: String
        var phases: [Phase]
    }
    @MainActor private final class Heartbeat {
        var gaps: [Double] = []
        var last = ContinuousClock.now
        var task: Task<Void, Never>?
        func start() {
            last = .now
            task = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    guard let self else { return }
                    let now = ContinuousClock.now
                    gaps.append(CommentPerformanceTests.milliseconds(last.duration(to: now))); last = now
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
    }

    /// 需显式启用；每次独立目录保留完整合成fixture，供之后隔离GUI复用。没有绝对性能阈值冒充平台保证。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_COMMENT_PERF"] == "1"))
    func largeStoreAndModelResponsiveness() async throws {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: environment["LOCALCLIP_COMMENT_PERF_OUTPUT"] ?? "/private/tmp/localclip-comments-round4", isDirectory: true).standardizedFileURL
        let resolved = base.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        // Foundation 对尚未创建的子目录可能保留 /private；两种系统临时目录别名都有效。
        try #require(resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/") || resolved.hasPrefix(temporary + "/"), "Performance output must be a temporary directory")
        let output = base.appendingPathComponent("large-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let counts = environment["LOCALCLIP_COMMENT_PERF_ROWS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [10_000, 100_000]
        try #require(!counts.isEmpty && counts.allSatisfy { $0 == 10_000 || $0 == 100_000 })
        print("COMMENT_PERF_OUTPUT=\(output.path)")
        for count in counts {
            let root = output.appendingPathComponent("fixture-\(count)", isDirectory: true)
            // BenchmarkGenerator 属于另一测试target；沿用它的 Schema + 单事务完整载荷seed方法，省去10万次持久化提交。
            let manifest = try await Task.detached(priority: .utility) { try Self.seed(root: root, count: count) }.value
            var report = Report(scope: "Synthetic text-only dataset. Service return and HistoryViewModel publication, no rendered UI, no OS cache flush. Heartbeat includes a 20ms trailing observation; CPU is the operation delta, RSS is the process lifetime high-water mark including fixture generation and earlier phases.", fixture: manifest, fixturePath: root.path, phases: [])
            let reportURL = output.appendingPathComponent("results-\(count).json")
            try Self.write(report, to: reportURL)
            var opened: HistoryStore?
            report.phases.append(try await measure("store-open-integrity-check") { opened = try HistoryStore(location: root) })
            let store = try #require(opened)
            report.phases.append(try await measure("service-first-page-first-call") {
                let page = try await store.search(.init())
                #expect(page.items.first?.id == "comment-perf-\(count - 1)")
                #expect(page.next != nil)
            })
            let queries = ["需求", "foo_bar", "END-\(count - 1)#", "comment-perf-no-match"]
            for round in 0..<3 {
                for query in queries {
                    report.phases.append(try await measure("service-search-\(round)-\(query)") {
                        let page = try await store.search(.init(query))
                        if query == "comment-perf-no-match" { #expect(page.items.isEmpty) }
                        else { #expect(!page.items.isEmpty) }
                        if query.hasPrefix("END-") { #expect(page.items.map(\.id) == ["comment-perf-\(count - 1)"]) }
                    })
                    try Self.write(report, to: reportURL)
                }
            }
            let board = MacPasteboardClient(access: RawBoard())
            let capture = CaptureCoordinator(board: board, store: store)
            let model = HistoryViewModel(store: store, capture: capture,
                paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
                derived: DerivedContentService(store: store))
            defer { capture.stop(); model.panelVisibilityChanged(false) }
            report.phases.append(try await measure("model-start-through-selected-metadata") {
                try await model.start(); capture.stop()
                try await self.wait { !model.historyBusy && !model.items.isEmpty && model.selectedMetadata?.summary.id == model.selectedID }
            })
            #expect(!model.settings.captureEnabled && !model.settings.autoCheckUpdates)
            for round in 0..<3 {
                for query in queries {
                    report.phases.append(try await measure("model-search-\(round)-\(query)") {
                        model.query = query; model.searchChanged(debounce: false)
                        try await self.wait { !model.historyBusy && (model.items.isEmpty || model.selectedMetadata?.summary.id == model.selectedID) }
                        if query == "comment-perf-no-match" { #expect(model.items.isEmpty) }
                        else { #expect(!model.items.isEmpty) }
                        if query.hasPrefix("END-") { #expect(model.items.map(\.id) == ["comment-perf-\(count - 1)"]) }
                    })
                    try Self.write(report, to: reportURL)
                }
            }
            model.query = ""; model.searchChanged(debounce: false)
            try await wait { !model.historyBusy && model.selectedMetadata?.summary.id == model.selectedID }
            report.phases.append(try await measure("model-refresh-existing-window") {
                let selection = model.selectedID
                model.refresh()
                try await self.wait { !model.historyBusy && model.selectedMetadata?.summary.id == model.selectedID }
                #expect(model.selectedID == selection)
            })
            try Self.write(report, to: reportURL)
            print("COMMENT_PERF rows=\(count) fixture=\(root.path) report=\(reportURL.path)")
        }
    }

    private func measure(_ name: String, operation: @MainActor () async throws -> Void) async throws -> Phase {
        let heartbeat = Heartbeat(); heartbeat.start()
        defer { heartbeat.stop() }
        // 让心跳先真正调度；同步的 HistoryStore init 若阻塞MainActor也会进入下一次 gap。
        try await Task.sleep(for: .milliseconds(20))
        heartbeat.gaps.removeAll(); heartbeat.last = .now
        let resourcesBefore = Self.resources(), begin = ContinuousClock.now
        try await operation()
        let duration = Self.milliseconds(begin.duration(to: .now)), resourcesAfter = Self.resources()
        try await Task.sleep(for: .milliseconds(20))
        let result = Phase(name: name, durationMs: duration, cpuSeconds: resourcesAfter.cpu - resourcesBefore.cpu,
            peakResidentBytes: resourcesAfter.memory, heartbeatIntervalMs: 10, heartbeatGapsMs: heartbeat.gaps,
            maximumHeartbeatGapMs: heartbeat.gaps.max() ?? 0, heartbeatGapsOver50Ms: heartbeat.gaps.filter { $0 > 50 }.count)
        print("COMMENT_PERF phase=\(name) durationMs=\(duration) maxMainActorGapMs=\(result.maximumHeartbeatGapMs)")
        return result
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), "Model did not settle within 60 seconds")
    }
    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    nonisolated private static func resources() -> (cpu: Double, memory: Int64) {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6, Int64(usage.ru_maxrss))
    }
    nonisolated private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    nonisolated private static func seed(root: URL, count: Int) throws -> Manifest {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("History/history.sqlite")
        let db = try SQLiteConnection(path)
        defer { try? db.close() }
        var settings = SettingsSnapshot()
        settings.quotaBytes = 4096 * MiB; settings.retentionDays = 365
        settings.captureEnabled = false; settings.autoCheckUpdates = false
        try db.exec("PRAGMA auto_vacuum=FULL"); try db.configure(); try Schema.create(db, settings: settings)
        try db.exec("BEGIN IMMEDIATE")
        let now = SystemClock().now(); var hash = SHA256(); var bytes: Int64 = 0
        let stems = ["今天整理需求，明天处理代码。", "The local clipboard keeps original representations.", "https://example.invalid/path?a=1&b=2#section", "let foo_bar = 50%; a->b; value; path/test\n"]
        for index in 0..<count {
            let base = "fixture-\(index) " + stems[index % stems.count] + "\n"
            let bucket = index % 100, desired = bucket < 90 ? 256 : bucket < 99 ? 2048 : 16384
            let text = String(repeating: base, count: max(1, desired / base.utf8.count)) + " END-\(index)#"
            let data = Data(text.utf8), id = "comment-perf-\(index)", digest = ContentFingerprint.hash(data)
            let payload = ClipboardPayload([.init([.init(SupportedType.string, data)], plainText: text)])
            bytes += Int64(data.count); hash.update(data: data)
            let time = now - Int64(count - index)
            try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceBundleID,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [.text(id), .text(payload.fingerprint), .integer(time), .integer(time), .integer(1), .text("text"), .integer(index % 20 == 0 ? 1 : 0), .null, .text("合成性能样本"), .text("unknown"), .text(String(text.prefix(180)))])
            try db.run("INSERT INTO items VALUES(?,?,?)", [.text(id), .integer(0), .text("[\"\(SupportedType.string)\"]")])
            try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(data.count)), .blob(data)])
            try db.run("INSERT INTO representations VALUES(?,?,?,?)", [.text(id), .integer(0), .text(SupportedType.string), .text(digest)])
            try db.run("INSERT INTO text_content VALUES(?,?,?,?)", [.text(id), .integer(0), .text(text), .text(SearchNormalizer.normalize(text))])
        }
        try db.exec("COMMIT")
        try #require(try db.scalarInt("SELECT COUNT(*) FROM clips") == Int64(count))
        try #require(try db.scalarText("PRAGMA integrity_check") == "ok")
        try #require(try db.rows("PRAGMA foreign_key_check").isEmpty)
        let manifest = Manifest(generator: "localclip-comment-text-scaling-v1", rows: count, payloadBytes: bytes,
            datasetSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            databaseBytes: try CommitStrategy.bytes(root.appendingPathComponent("History")), createdAtMs: now)
        try write(manifest, to: root.appendingPathComponent("fixture-manifest.json"))
        return manifest
    }
}
