// 缩略图预算、隐藏清理和恢复回归，使用隔离数据，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct ThumbnailMemoryTests {
    /// 并行功能测试可能占用主线程，用条件等待而不是固定睡眠判定清理完成。
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    /// 真实位图尺寸参与成本，不能以压缩PNG大小代替解码内存。
    private func image(_ side: Int = 100) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32))
        let image = NSImage(size: .init(width: side, height: side)); image.addRepresentation(bitmap)
        return image
    }
    /// 超预算淘汰最久未用项；替换不重复计费；超大图不进入缓存。
    @Test func boundedLRUAndReplacement() throws {
        let cache = ThumbnailMemoryCache(byteLimit: 80_000)
        cache.setObject(try image(), forKey: "a")
        cache.setObject(try image(), forKey: "b")
        #expect(cache.byteCount == 80_000)
        #expect(cache.object(forKey: "a") != nil)
        cache.setObject(try image(), forKey: "c")
        #expect(cache.object(forKey: "b") == nil)
        #expect(cache.object(forKey: "a") != nil)
        cache.setObject(try image(50), forKey: "a")
        #expect(cache.byteCount == 50_000)
        cache.setObject(try image(200), forKey: "large")
        #expect(cache.object(forKey: "large") == nil)
        #expect(cache.byteCount == 50_000)
        cache.retainOnly(["c"])
        #expect(cache.byteCount == 40_000)
        #expect(cache.object(forKey: "a") == nil)
    }
    /// 清理任务可取消；长期隐藏保留当前屏，重新打开不丢失选择/查询/图片。
    @Test func delayedCleanupPreservesViewportAndQuickReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        model.thumbnailCleanupDelay = .milliseconds(80)
        model.thumbnails.setObject(try image(), forKey: "visible")
        model.thumbnails.setObject(try image(), forKey: "offscreen")
        model.thumbnailVisibilityChanged(id: "visible", visible: true)
        model.query = "unchanged"
        model.panelVisibilityChanged(false)
        model.thumbnailVisibilityChanged(id: "visible", visible: false)
        model.panelVisibilityChanged(true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.thumbnails.object(forKey: "offscreen") != nil)
        model.panelVisibilityChanged(false)
        try await wait { model.thumbnails.object(forKey: "offscreen") == nil }
        #expect(model.thumbnails.object(forKey: "offscreen") == nil)
        #expect(model.thumbnails.object(forKey: "visible") != nil)
        model.panelVisibilityChanged(true)
        #expect(model.query == "unchanged")
        #expect(model.thumbnails.object(forKey: "visible") != nil)
        // 再次变更视口，旧屏不能永久受保护。
        model.thumbnailVisibilityChanged(id: "visible", visible: false)
        model.panelVisibilityChanged(false)
        try await wait { model.thumbnails.byteCount == 0 }
        #expect(model.thumbnails.byteCount == 0)
        // 重复取消、清理和切换视口，验证同一实例不会累积旧屏保护项或误清当前屏。
        for cycle in 0..<8 {
            model.panelVisibilityChanged(true)
            let visibleID = "viewport-\(cycle)", offscreenID = "offscreen-\(cycle)"
            let visibleImage = try image()
            model.thumbnails.setObject(visibleImage, forKey: visibleID as NSString)
            model.thumbnails.setObject(try image(), forKey: offscreenID as NSString)
            model.thumbnailVisibilityChanged(id: visibleID, visible: true)
            model.panelVisibilityChanged(false)
            model.panelVisibilityChanged(true)
            try await Task.sleep(for: .milliseconds(120))
            #expect(model.thumbnails.object(forKey: offscreenID as NSString) != nil)
            model.panelVisibilityChanged(false)
            try await wait { model.thumbnails.object(forKey: offscreenID as NSString) == nil }
            #expect(model.thumbnails.object(forKey: visibleID as NSString) === visibleImage)
            #expect(model.thumbnails.byteCount == 40_000)
            model.panelVisibilityChanged(true)
            #expect(model.query == "unchanged")
            #expect(model.thumbnails.object(forKey: visibleID as NSString) === visibleImage)
            model.thumbnailVisibilityChanged(id: visibleID, visible: false)
            model.panelVisibilityChanged(false)
            try await wait { model.thumbnails.byteCount == 0 }
        }
    }
    /// 清理编码缓存只影响可再生内存，持久缩略图、原图和修订号保持不变。
    @Test func encodedCacheReloadPreservesOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let data = try ImageFixtures.image(width: 120, height: 90)
        let payload = ClipboardPayload([.init([.init(SupportedType.png, data)])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now) else { Issue.record("fixture"); return }
        let original = try await store.detail(id: id, at: now)
        #expect(try await store.cacheThumbnail(id: id, revision: original.revision, data: data))
        await store.releaseThumbnailMemoryCache()
        #expect(try await store.thumbnail(id: id, at: now) == data)
        let after = try await store.detail(id: id, at: now)
        #expect(after.payload == original.payload)
        #expect(after.revision == original.revision)
    }
}
