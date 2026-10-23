// A2后台图片文字索引：临时库 + 私有fake剪贴板 + 可控识别器；另有一条本地Vision端到端用例，不读取用户图片或剪贴板，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

/// 识别器在测试放行前挂起，用于制造“识别进行中”的交错。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = [], open = false, entered = 0
    var arrivals: Int { lock.withLock { entered } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in entered += 1; if open { return true }; waiters.append(continuation); return false }
            if resume { continuation.resume() }
        }
    }
    func release() { let pending = lock.withLock { open = true; defer { waiters = [] }; return waiters }; pending.forEach { $0.resume() } }
}
private final class Calls: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

@MainActor struct ImageTextIndexerTests {
    private struct Harness { let root: URL, store: HistoryStore, raw: RawBoard, model: HistoryViewModel }
    private func harness(_ settings: SettingsSnapshot = .init()) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root, initialSettings: settings), raw = RawBoard(), board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        return .init(root: root, store: store, raw: raw, model: model)
    }
    private func until(_ predicate: () async throws -> Bool, line: Int = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await predicate(), "line \(line)")
    }
    private func ids(_ store: HistoryStore, _ text: String) async throws -> [ClipID] { try await store.search(.init(text)).items.map(\.id) }
    private func image(_ seed: Int) throws -> Data { try ImageFixtures.image(width: 8 + seed, height: 8) }
    private func ingest(_ store: HistoryStore, _ items: [PasteboardItemValue]) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init(items)), at: SystemClock().now()) else { throw StoreError.notFound }
        return id
    }
    private static func rawCount(_ root: URL) throws -> Int64 {
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite")); defer { try? db.close() }
        return try db.scalarInt("SELECT COUNT(*) FROM image_text")
    }
    private static func rendered(_ text: String) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4,
                                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 30, y: 50))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    /// 开启后新复制的图片在后台识别，搜索其中短语命中原图；不写系统剪贴板、不新增文字历史、不改复制次数。
    /// 开启前已有的图片不自动识别，只在用户明确触发后建立索引。
    @Test func newImagesIndexedInBackgroundAndBackfillIsExplicit() async throws {
        let h = try await harness(); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let older = try await ingest(h.store, [.init([.init(SupportedType.png, try image(1))])])
        try await h.model.start(); h.model.capture.stop()
        h.model.imageTextIndexer.recognize = { payload in
            payload.items.first?.representations.first?.data.count == (try? ImageFixtures.image(width: 9, height: 8).count) ? ["Old Receipt 1024"] : ["Launch Plan 7319"]
        }
        h.model.setImageTextSearch(true)
        try await until { h.model.settings.imageTextSearchSince != nil }
        try await Task.sleep(for: .milliseconds(5))
        let writes = h.raw.count
        let copied = try image(2)
        h.raw.count += 1; h.raw.items = [[SupportedType.png: copied]]; h.model.capture.tick()
        let shot = try await { () async throws -> ClipID in
            try await until { try await h.store.search(.init()).items.count == 2 }
            return try #require(try await h.store.search(.init()).items.first?.id)
        }()
        try await until { try await ids(h.store, "launch plan") == [shot] }
        #expect(h.raw.count == writes + 1 && h.raw.items == [[SupportedType.png: copied]])
        #expect(try await h.store.search(.init()).items.count == 2)
        #expect(try await h.store.search(.init()).items.first(where: { $0.id == shot })?.copyCount == 1)
        try await until { !h.model.imageTextIndexing }
        #expect(try await ids(h.store, "receipt").isEmpty)
        h.model.indexExistingImages()
        try await until { try await ids(h.store, "old receipt") == [older] }
        try await until { h.model.imageTextStatus?.hasPrefix("已有图片文字索引完成") == true }
        // 开启状态下清除：之后的变更不会把已清除的图片自动重新识别。
        // 设置保存自身的变更事件可能先于新起点写回界面状态到达：此刻按旧起点触发同步，也不能重新识别。
        let enabledAt = try #require(h.model.settings.imageTextSearchSince)
        h.model.clearImageTextIndex(); h.model.syncImageTextIndex()
        try await until { h.model.imageTextStatus == "已清除图片文字索引" && (h.model.settings.imageTextSearchSince ?? 0) > enabledAt && h.model.imageTextIndexer.task == nil }
        #expect(try await ids(h.store, "launch plan").isEmpty)
        // 与存储变更事件同一入口触发并等本轮跑完，不靠固定sleep猜事件循环时序。
        _ = try await h.store.apply(try await h.store.preview(.favorite(older, true)).token)
        h.model.syncImageTextIndex()
        try await until { h.model.imageTextIndexer.task == nil }
        #expect(try await ids(h.store, "launch plan").isEmpty && h.model.imageTextStatus == "已清除图片文字索引")
        h.model.indexExistingImages()
        try await until { try await ids(h.store, "launch plan") == [shot] }
        // 关闭后不再命中；再开启复用已有索引。
        h.model.setImageTextSearch(false)
        try await until { h.model.settings.imageTextSearchSince == nil }
        #expect(try await ids(h.store, "launch plan").isEmpty)
    }

    /// 识别进行中停止、关闭功能、开启隐藏内容或删除原图：在途结果都不能入库，也不留下可检索残留。
    @Test(arguments: ["stop", "disable", "hide", "delete"])
    func inFlightResultsAreDropped(action: String) async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let shot = try await ingest(h.store, [.init([.init(SupportedType.png, try image(3))])])
        let gate = Gate()
        h.model.imageTextIndexer.recognize = { _ in await gate.wait(); return ["Secret Draft 4242"] }
        try await h.model.start(); h.model.capture.stop()
        h.model.indexExistingImages()
        try await until { gate.arrivals == 1 }
        switch action {
        case "stop": h.model.stopImageTextIndexing()
        case "disable": h.model.setImageTextSearch(false); try await until { h.model.settings.imageTextSearchSince == nil }
        case "hide": h.model.updateSettings { $0.hideContents = true }; try await until { h.model.settings.hideContents }
        default: _ = try await h.store.apply(try await h.store.preview(.delete([shot])).token)
        }
        gate.release()
        try await until { h.model.imageTextIndexer.task == nil }
        try await Task.sleep(for: .milliseconds(100))
        // 恢复设置前直接查库：在途结果从未写入，而不是被之后的查询条件遮住。
        #expect(try Self.rawCount(h.root) == 0)
        #expect(try await h.store.pendingImageText(since: nil).count == (action == "delete" ? 0 : 1))
    }

    /// 同一图片项多种表示只识别一次，首个无法解码时改用下一种；无文字、损坏图记空结果，再次触发不重复识别；多图片记录逐项可检索。
    @Test func formatsFailuresAndMultipleItems() async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let tiff = try ImageFixtures.image(width: 12, height: 8, type: SupportedType.tiff)
        let broken = Representation(SupportedType.png, Data("not an image".utf8))
        let album = try await ingest(h.store, [.init([.init(SupportedType.png, try image(4)), .init(SupportedType.tiff, tiff)]), .init([broken, .init(SupportedType.tiff, tiff)])])
        let blank = try await ingest(h.store, [.init([.init(SupportedType.png, try image(5))])])
        let calls = Calls()
        h.model.imageTextIndexer.recognize = { payload in
            calls.add()
            let representation = try #require(payload.items.first?.representations.first)
            if representation.data == broken.data { throw ImageTextRecognizer.Failure(message: "图片无法解码") }
            if representation.data == (try? ImageFixtures.image(width: 13, height: 8)) { throw ImageTextRecognizer.Failure(message: "未识别到文字") }
            return [representation.type == SupportedType.tiff ? "Second Page Total" : "First Page Header"]
        }
        try await h.model.start(); h.model.capture.stop()
        h.model.indexExistingImages()
        try await until { try await h.store.pendingImageText(since: nil).isEmpty && !h.model.imageTextIndexing }
        #expect(calls.count == 4)
        #expect(try await ids(h.store, "first page header") == [album])
        #expect(try await ids(h.store, "second page total") == [album])
        #expect(try await ids(h.store, "page").contains(blank) == false)
        h.model.indexExistingImages()
        try await until { !h.model.imageTextIndexing }
        #expect(calls.count == 4)
        // 手动“复制图中文字”与后台索引分开：关闭本功能后仍可用。
        h.model.setImageTextSearch(false)
        try await until { h.model.settings.imageTextSearchSince == nil }
        h.model.recognizeImageText = { _ in ["Manual Copy 55"] }
        h.model.copyImageText(id: album)
        await h.model.imageTextTask?.value
        #expect(h.raw.items.first?[SupportedType.string].map { String(decoding: $0, as: UTF8.self) } == "Manual Copy 55")
    }

    /// 较新的一条记录原图损坏：只跳过该项，后面的图片照常建立索引，不卡住整个队列。
    @Test func corruptRecordDoesNotBlockQueue() async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let good = try await ingest(h.store, [.init([.init(SupportedType.png, try image(7))])])
        let bad = try image(8)
        _ = try await ingest(h.store, [.init([.init(SupportedType.png, bad)])])
        let db = try SQLiteConnection(h.root.appendingPathComponent("History/history.sqlite")); defer { try? db.close() }
        try db.run("UPDATE blobs SET payload=zeroblob(byteCount) WHERE digest=?", [.text(ContentFingerprint.hash(bad))])
        h.model.imageTextIndexer.recognize = { _ in ["Healthy Page"] }
        try await h.model.start(); h.model.capture.stop()
        h.model.indexExistingImages()
        try await until { !h.model.imageTextIndexing && h.model.imageTextStatus?.hasPrefix("已有图片文字索引完成") == true }
        #expect(try await ids(h.store, "healthy page") == [good])
    }

    /// 关闭开关仍在保存时点“清除”：清除不能把用户刚关闭的隐私开关重新打开。
    @Test func disableThenClearStaysDisabled() async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        try await h.model.start(); h.model.capture.stop()
        h.model.setImageTextSearch(false); h.model.clearImageTextIndex()
        try await until { h.model.imageTextStatus == "已清除图片文字索引" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.model.settings.imageTextSearchSince == nil)
        #expect(try await h.store.settings().imageTextSearchSince == nil)
    }

    /// 容量不足：停止索引并说明，不淘汰历史。
    @Test func capacityStopsIndexing() async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1; settings.quotaBytes = 512 * 1024
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let shot = try await ingest(h.store, [.init([.init(SupportedType.png, Data(repeating: 7, count: 100 * 1024))])])
        let calls = Calls()
        h.model.imageTextIndexer.recognize = { _ in calls.add(); return [String(repeating: "overflow ", count: 60_000)] }
        try await h.model.start(); h.model.capture.stop()
        h.model.indexExistingImages()
        try await until { h.model.imageTextStatus == "存储空间不足，已停止图片文字索引；历史未受影响" && !h.model.imageTextIndexing }
        #expect(try await h.store.search(.init()).items.map(\.id) == [shot])
        // 停止后新复制不再触发自动重识别，直到用户再次手动建立索引。
        let before = calls.count
        let next = try await ingest(h.store, [.init([.init(SupportedType.png, try image(6))])])
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.count == before && h.model.imageTextIndexer.task == nil)
        #expect(try await h.store.search(.init()).items.map(\.id) == [next, shot])
    }

    /// 端到端：本地Vision识别合成截图，按图中短语找回原图；文件名与识别词从未作为文字复制。
    @Test func localVisionFindsOriginalScreenshot() async throws {
        var settings = SettingsSnapshot(); settings.imageTextSearchSince = 1
        let h = try await harness(settings); defer { h.model.capture.stop(); try? FileManager.default.removeItem(at: h.root) }
        let shot = try await ingest(h.store, [.init([.init(SupportedType.png, try Self.rendered("LOCALCLIP INVOICE 7319"))])])
        try await h.model.start(); h.model.capture.stop()
        h.model.indexExistingImages()
        try await until { !h.model.imageTextIndexing && h.model.imageTextStatus?.hasPrefix("已有图片文字索引完成") == true }
        #expect(try await ids(h.store, "invoice 7319") == [shot])
        #expect(try await h.store.search(.init("invoice", kind: .image)).items.map(\.id) == [shot])
    }
}
