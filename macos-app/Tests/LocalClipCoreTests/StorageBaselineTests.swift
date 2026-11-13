// 合成库仅用于测量，夹具构造与清理不计入样本，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_STORAGE_BASELINE"] == "1"))
struct StorageBaselineTests {
    private let now = SystemClock().now()

    @Test func metadataDuringStorageOperations() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("Store")
        let database = try seed(location, count: 13, bytes: Int(20 * MiB), text: false)
        let store = try HistoryStore(location: location)
        let image = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.png, Data(repeating: 170, count: Int(50 * MiB)))])]))
        let id = insertedID(try await store.ingest(image, at: now))
        try #require(!id.isEmpty)
        try await measureQueue("duplicate-50MiB", store: store) { store in
            let result = try store.ingest(.init(payload: image.payload), at: image.capturedAt)
            #expect(result == .deduplicated(id))
        }

        let source = root.appendingPathComponent("synthetic.bin")
        let file = ClipboardSnapshot(payload: .init([.init([.init(SupportedType.fileURL, Data(source.absoluteString.utf8))])]))
        try Data(repeating: 171, count: Int(50 * MiB) - 4096).write(to: source)
        try await measureQueue("file-copy-50MiB", store: store) { store in
            let fileID = insertedID(try store.ingest(file, at: file.capturedAt))
            try #require(!fileID.isEmpty)
        }
        let check = try SQLiteConnection(database, readonly: true)
        #expect(try check.scalarInt("SELECT MAX(byteCount) FROM file_copies") == 50 * MiB - 4096)
        try check.close()

        // 临时占用填到上限，确保实际进入 canCapture 的回滚预演，by AI.Coding。
        let exports = location.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let filler = exports.appendingPathComponent("filler")
        try Data().write(to: filler)
        let handle = try FileHandle(forWritingTo: filler)
        let quota = try await store.settings().quotaBytes
        let before = try await store.usage().measuredTotal
        try handle.truncate(atOffset: UInt64(quota - before + MiB))
        try handle.close()
        #expect(try await store.usage().measuredTotal >= quota)
        for phase in ["first", "cached"] {
            try await measureQueue("canCapture-at-quota-\(phase)", store: store) { store in
                let canCapture = try store.canCapture()
                #expect(canCapture)
            }
        }
        try FileManager.default.removeItem(at: filler)

        let integrityRoot = root.appendingPathComponent("Integrity")
        _ = try seed(integrityRoot, count: 13, bytes: Int(20 * MiB), text: false)
        let integrityStore = try HistoryStore(location: integrityRoot)
        try await measureQueue("integrityCheck-260MiB", store: integrityStore) { store in
            let valid = try store.integrityCheck()
            #expect(valid)
        }
    }

    @Test(arguments: [false, true]) func literalPaging(longText: Bool) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let count = longText ? 1000 : 50_000
        _ = try seed(root, count: count, bytes: longText ? Int(MiB) : 96, text: true)
        let store = try HistoryStore(location: root)
        var samples: [Double] = []
        for index in 0..<10 {
            var request = SearchRequest("needle-\(index):", pageSize: 50)
            request.countTotal = true
            request.offset = index.isMultiple(of: 2) ? 0 : count / 10 - 50
            let start = ContinuousClock.now
            let page = try await store.search(request)
            samples.append(milliseconds(since: start))
            #expect(page.total == count / 10 && page.items.count == 50)
        }
        printSamples("M4 rows=\(count)", samples)
    }

    @Test(arguments: [260, 2048]) func openAndRecover(sizeMiB: Int) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = sizeMiB == 260 ? 20 : 32
        let url = try seed(root, count: sizeMiB / chunk, bytes: Int(Int64(chunk) * MiB), text: false)
        let bytes = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            let store = try HistoryStore(location: root)
            _ = try await store.recover()
            samples.append(milliseconds(since: start))
        }
        printSamples("M5 size=\(sizeMiB)MiB actualBytes=\(bytes)", samples)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    // 使用实际 Schema 和有效摘要批量造库，避免逐条同步提交主导夹具构造，by AI.Coding。
    private func seed(_ root: URL, count: Int, bytes: Int, text: Bool) throws -> URL {
        var settings = SettingsSnapshot()
        settings.quotaBytes = 4096 * MiB
        _ = try HistoryStore(location: root, initialSettings: settings)
        let database = root.appendingPathComponent("History/history.sqlite")
        let db = try SQLiteConnection(database)
        try db.configure()
        try db.exec("BEGIN IMMEDIATE")
        for index in 0..<count {
            let prefix = "fixture-\(index) needle-\(index % 10): "
            let value = text ? prefix + String(repeating: "x", count: bytes - prefix.utf8.count) : ""
            var data = text ? Data(value.utf8) : Data(repeating: 0x5a, count: bytes)
            if !text { data.replaceSubrange(0..<prefix.utf8.count, with: prefix.utf8) }
            let type = text ? SupportedType.string : SupportedType.png
            let payload = ClipboardPayload([.init([.init(type, data)])])
            let digest = ContentFingerprint.hash(data)
            let id = "baseline-\(index)"
            try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,1,?,0,'来源未知','unknown',?)",
                       [.text(id), .text(payload.fingerprint), .integer(now), .integer(now + Int64(index)), .text(payload.kind.rawValue), .text(String(prefix.prefix(180)))])
            try db.run("INSERT INTO items VALUES(?,?,?)", [.text(id), .integer(0), .text("[\"\(type)\"]")])
            try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(bytes)), .blob(data)])
            try db.run("INSERT INTO representations VALUES(?,?,?,?)", [.text(id), .integer(0), .text(type), .text(digest)])
            if text {
                // 合成文本全为小写 ASCII，已经符合检索规范化规则，by AI.Coding。
                try db.run("INSERT INTO text_content VALUES(?,?,?,?)", [.text(id), .integer(0), .text(value), .text(value)])
            }
        }
        try db.exec("COMMIT")
        try db.close()
        return database
    }

    // 重操作先进入 actor；发出信号后到操作结束之间没有挂起点，by AI.Coding。
    private func run(_ store: isolated HistoryStore, entered: AsyncStream<Void>.Continuation,
                     operation: @Sendable (isolated HistoryStore) throws -> Void) throws {
        entered.yield()
        entered.finish()
        try operation(store)
    }

    private func measureQueue(_ label: String, store: HistoryStore,
                              operation: @escaping @Sendable (isolated HistoryStore) throws -> Void) async throws {
        let (entered, signal) = AsyncStream<Void>.makeStream()
        async let heavy: Void = run(store, entered: signal, operation: operation)
        for await _ in entered {
            let samples = try await withThrowingTaskGroup(of: Double.self, returning: [Double].self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        let start = ContinuousClock.now
                        _ = try await store.metadata(id: "baseline-0", at: now)
                        return milliseconds(since: start)
                    }
                }
                var result: [Double] = []
                for try await sample in group { result.append(sample) }
                return result
            }
            printSamples("M3 \(label)", samples)
        }
        try await heavy
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private func printSamples(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        print("\(name) n=\(samples.count) p50=\(median) p95=\(sorted[Int(ceil(Double(samples.count) * 0.95)) - 1]) max=\(sorted.last!) samples=\(samples)")
    }
}
