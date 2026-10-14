// 指定报告的搜索规模、候选投影和可取消修复验证，全部使用合成库，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

struct SpecifiedReviewSearchTests {
    /// 一次事务构造合法表示/哈希/索引，避免基准把逐条生产提交时间混入查询时间。
    private func fixtureStore(count: Int, indexed: Bool = true) throws -> (URL, HistoryStore, [ClipID]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); try db.configure()
        try db.exec("BEGIN")
        var ids: [ClipID] = []
        let now = SystemClock().now()
        for index in 0..<count {
            let id = UUID().uuidString, text = "review-needle 中文 \(index) tail"
            let bytes = Data(text.utf8), payload = ClipboardPayload([.init([.init(SupportedType.string, bytes)])])
            let digest = ContentFingerprint.hash(bytes); ids.append(id)
            try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,1,'text',0,'fixture','unknown',?)", [.text(id), .text(payload.fingerprint), .integer(now), .integer(now + Int64(index)), .text(text)])
            try db.run("INSERT INTO items VALUES(?,0,?)", [.text(id), .text("[\"public.utf8-plain-text\"]")])
            try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(bytes.count)), .blob(bytes)])
            try db.run("INSERT INTO representations VALUES(?,0,?,?)", [.text(id), .text(SupportedType.string), .text(digest)])
            if indexed { try db.run("INSERT INTO text_content VALUES(?,0,?,?)", [.text(id), .text(text), .text(SearchNormalizer.normalize(text))]) }
        }
        try db.exec("UPDATE store_meta SET storeRevision=1; COMMIT"); try db.close()
        return (root, store, ids)
    }

    /// LC-005：候选边界和分页返回顺序保持一致；最多只返回一份候选JSON。
    @Test(arguments: [0, 1, 5000, 5001])
    func candidateEnvelopeBoundary(count: Int) async throws {
        let (root, store, ids) = try fixtureStore(count: count)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [1, 8, 50] {
            let page = try await store.search(.init("review-needle", pageSize: size))
            #expect(page.items.map(\.id) == Array(ids.reversed().prefix(size)))
            #if DEBUG
            #expect(await store.lastCandidateProjectionBytes == (count > 5000 ? 0 : count == 0 ? 2 : 39 * count + 1))
            #endif
            if let next = page.next {
                let second = try await store.search(.init("review-needle", cursor: next, pageSize: size))
                #expect(second.items.map(\.id) == Array(ids.reversed().dropFirst(size).prefix(size)))
            #if DEBUG
                #expect(await store.lastCandidateProjectionBytes == 0)
            #endif
            }
        }
    }

    /// LC-001：4096/4097真实不同ID边界；预览计数与保护数量准确，取消无写入。
    @Test func deletionCountBoundaryAndStalePreview() async throws {
        let (root, store, ids) = try fixtureStore(count: 4097)
        defer { try? FileManager.default.removeItem(at: root) }
        let favorite = try await store.preview(.favorite(ids[0], true)); _ = try await store.apply(favorite.token)
        let small = try await store.preview(.delete(Array(ids.prefix(4096))))
        let large = try await store.preview(.delete(ids + [ids[0], "missing"]))
        #expect(small.canUndo == true && !small.requiresConfirmation)
        #expect(large.affectedCount == 4097 && large.protectedCount == 1 && large.canUndo == false && large.requiresConfirmation)
        try await store.renameClip(id: ids[0], title: "changed")
        await #expect(throws: StoreError.stalePreview) { try await store.apply(large.token) }
        #expect(try await store.metadata(id: ids[0], at: SystemClock().now()).summary.title == "changed")
    }

    /// LC-006：缺索引结果完整；挂起查询期间存储actor可响应，取消不改原始数据。
    @Test func repairYieldsAndCancellationPreservesHistory() async throws {
        let (root, store, ids) = try fixtureStore(count: 1000, indexed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = Task { try await store.search(.init("tail")) }
        await Task.yield()
        _ = try await store.metadata(id: ids[0], at: SystemClock().now())
        pending.cancel()
        do { _ = try await pending.value } catch is CancellationError { }
        let page = try await store.search(.init("tail"))
        #expect(page.items.map(\.id) == Array(ids.reversed().prefix(50)))
        #expect(try await store.rebuildSearchIndex(limit: 3) == 3)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        #expect(try db.scalarInt("SELECT COUNT(*) FROM clips") == 1000)
        try db.close()
    }

    /// LC-005/006：同构建合成查询原始样本；仅测试宿主，不冒充GUI首帧或RSS。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_BENCHMARK"] == "1"))
    func nativeSearchSamples() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_BENCHMARK_OUTPUT"])
        var result: [[String: Any]] = []
        for indexed in [true, false] {
            let (root, store, _) = try fixtureStore(count: 5000, indexed: indexed)
            defer { try? FileManager.default.removeItem(at: root) }
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = ContinuousClock.now
                let page = try await store.search(.init("review-needle"), onlyIDs: nil)
                #expect(page.items.count == 50)
                let duration = start.duration(to: .now).components
                samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            }
            result.append(["indexed": indexed, "count": 5000, "pageSize": 50, "milliseconds": samples])
        }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
