// 图像真实编码与界面旧响应失效验证，by AI.Coding。
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import LocalClipCore
@testable import LocalClipMac
struct ImageFixtures {
    /// 固定色块，返回实际编码图片而非伪header。
    static func image(width: Int, height: Int, type: String = SupportedType.png) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StoreError.ioFailure }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(.init(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1)); context.fill(.init(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw StoreError.ioFailure }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { throw StoreError.ioFailure }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.ioFailure }
        return output as Data
    }
}
@MainActor struct DerivedAndViewModelTests {
    /// 第一页同时到期后重查，下一页中的旧收藏仍然出现。
    @Test func AC19_E02_expiredPageRevealsOlderFavorite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ViewModelClock(), store = try HistoryStore(location: root, clock: clock)
        guard case .inserted(let favoriteID) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("OLDER-FAVORITE".utf8))])])), at: clock.now()) else { Issue.record("缺favorite fixture"); return }
        let preview = try await store.preview(.favorite(favoriteID, true)); _ = try await store.apply(preview.token)
        clock.advance(31 * dayMS)
        for index in 0..<50 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("EXPIRING-PAGE-\(index)".utf8))])])), at: clock.now() - 30 * dayMS + 150) }
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture, clock: clock), derived: DerivedContentService(store: store), clock: clock)
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(3)
        while model.items.count != 50, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.items.count == 50); #expect(model.hasMore)
        clock.advance(150)
        let expired = ContinuousClock.now + .seconds(3)
        while model.items.map(\.id) != [favoriteID], ContinuousClock.now < expired { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.items.map(\.id) == [favoriteID]); #expect(!model.hasMore)
    }
    /// 不触发新查询或物理清理，已显示普通内容在截止时消失，收藏继续可见。
    @Test func AC19_E02_publishedExpiryDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ViewModelClock(), store = try HistoryStore(location: root, clock: clock)
        let copied = clock.now() - 30 * dayMS + 150
        let ordinary = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("EXPIRES-VISIBLE".utf8))])])), at: copied)
        let favorite = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("FAVORITE-VISIBLE".utf8))])])), at: copied)
        guard case .inserted(let id) = ordinary, case .inserted(let favoriteID) = favorite else { Issue.record("缺expiry fixture"); return }
        let preview = try await store.preview(.favorite(favoriteID, true)); _ = try await store.apply(preview.token)
        let raw = RawBoard(), board = MacPasteboardClient(access: raw)
        let capture = CaptureCoordinator(board: board, store: store, clock: clock)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture, clock: clock), derived: DerivedContentService(store: store), clock: clock)
        try await model.start(); capture.stop()
        let ready = ContinuousClock.now + .seconds(3)
        while model.items.count != 2, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        model.select(id); model.showingDetail = true; model.detailVisibilityChanged()
        while model.detail?.summary.id != id, ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.detail?.summary.id == id)
        clock.advance(150)
        let expired = ContinuousClock.now + .seconds(3)
        while model.items.contains(where: { $0.id == id }), ContinuousClock.now < expired { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.items.map(\.id) == [favoriteID]); #expect(model.selectedID != id); #expect(model.detail?.summary.id != id); #expect(model.image == nil)
        #expect(try await store.search(.init()).items.map(\.id) == [favoriteID])
    }
    /// 真正UI调用链在正文读取期间请求暂停，在途A不落库，恢复仅保存新的B。
    @Test func AC11_E04_modelPauseGateAndSaveFailure() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // 写入改为原库事务；锁住数据库目录使回滚日志无法创建，即真实的保存失败，by AI.Coding。
        let staging=root.appendingPathComponent("History")
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:staging.path); try? FileManager.default.removeItem(at:root) }
        let store=try HistoryStore(location:root),raw=RawBoard(),apps=FakeApplications()
        let board=MacPasteboardClient(access:raw),capture=CaptureCoordinator(board:board,store:store)
        let model=HistoryViewModel(store:store,capture:capture,paste:PasteCoordinator(board:board,applications:apps,store:store,capture:capture),derived:DerivedContentService(store:store))
        try await model.start(); capture.stop()
        // 文件系统拒绝保存时不显示配置成功，解除临时gate也不补采暂停期间内容。
        try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath:staging.path)
        model.updateSettings { $0.captureEnabled=false }; #expect(capture.state == "正在暂停")
        let failureDeadline=ContinuousClock.now + .seconds(3)
        while !model.message.contains("设置保存失败"), ContinuousClock.now < failureDeadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(model.message.contains("设置保存失败")); #expect(try await store.settings().captureEnabled); #expect(capture.policy.captureEnabled)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:staging.path)
        raw.onRead = { _,_ in raw.onRead=nil; model.updateSettings { $0.captureEnabled=false } }
        raw.user("IN-FLIGHT-A"); capture.tick()
        let pauseDeadline=ContinuousClock.now + .seconds(3)
        while model.settings.captureEnabled, ContinuousClock.now < pauseDeadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(!model.settings.captureEnabled); #expect(try await store.search(.init()).items.isEmpty)
        model.updateSettings { $0.captureEnabled=true }
        let resumeDeadline=ContinuousClock.now + .seconds(3)
        while !model.settings.captureEnabled, ContinuousClock.now < resumeDeadline { try await Task.sleep(for:.milliseconds(10)) }
        raw.user("NEW-B"); capture.tick()
        let saveDeadline=ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.count != 1, ContinuousClock.now < saveDeadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(try await store.search(.init()).items.first?.preview == "NEW-B"); capture.stop()
    }
    /// 方向键越过第一页，加载下一页并选中第51条，全程不依赖鼠标。
    @Test func E01_keyboardAcrossPageBoundary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try HistoryStore(location:root)
        for index in 0..<55 { _ = try await store.ingest(.init(payload:.init([.init([.init(SupportedType.string,Data("keyboard-history-\(index)".utf8))])])),at:SystemClock().now()+Int64(index)) }
        let raw=RawBoard(),board=MacPasteboardClient(access:raw),apps=FakeApplications()
        let capture=CaptureCoordinator(board:board,store:store)
        let model=HistoryViewModel(store:store,capture:capture,paste:PasteCoordinator(board:board,applications:apps,store:store,capture:capture),derived:DerivedContentService(store:store))
        try await model.start(); defer { capture.stop() }
        let deadline=ContinuousClock.now + .seconds(3)
        while model.items.count != 50, ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(model.items.count == 50); #expect(model.hasMore)
        guard let last=model.items.last else { return }; model.select(last.id); model.navigate(1)
        let pageDeadline=ContinuousClock.now + .seconds(3)
        while model.items.count != 55, ContinuousClock.now < pageDeadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(model.items.count == 55); #expect(!model.hasMore); #expect(model.selectedID == model.items[50].id)
    }
    /// 各编码下采样，40MP以上保留原始数据且不解码预览。
    @Test func AC06_AC25_imagePreviewBoundary() async throws {
        for type in [SupportedType.png, SupportedType.tiff, SupportedType.jpeg] {
            let encoded = try ImageFixtures.image(width: 1920, height: 1080, type: type)
            let payload = ClipboardPayload([.init([.init(type, encoded)])])
            let result = await Task.detached { ThumbnailRenderer.render(payload) }.value
            guard case .image(let data) = result, let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { Issue.record("预览失败 \(type)"); continue }
            #expect(image.width == 800); #expect(image.height == 450)
            #expect(payload.items[0].representations[0].data == encoded)
        }
        let large = try ImageFixtures.image(width: 6401, height: 6400)
        let result = await Task.detached { ThumbnailRenderer.render(.init([.init([.init(SupportedType.png, large)])])) }.value
        if case .tooManyPixels = result {} else { Issue.record("40MP保护失效") }
        // 超限表示仍不解码，但同一条记录中的安全备用图片应自动显示，by AI.Coding。
        let fallback = try ImageFixtures.image(width: 32, height: 24, type: SupportedType.tiff)
        let alternatives = ClipboardPayload([.init([.init(SupportedType.png, large), .init(SupportedType.tiff, fallback)])])
        if case .image = ThumbnailRenderer.render(alternatives) {} else { Issue.record("安全备用预览被超限表示遮蔽") }
    }
    /// 新查询立即作废旧queryID；删除选中项后详情和恢复不可见。
    @Test func E02_AC14_viewModelQueryAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for text in ["old-query", "最新需求"] { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: SystemClock().now()) }
        let raw = RawBoard(); let board = MacPasteboardClient(access: raw); let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); defer { capture.stop() }
        model.query = "old"; model.searchChanged(); model.query = "需求"; model.searchChanged()
        // 并发图片测试可能占用主线程；等待条件是正确结果，不用固定睡眠伪造性能证明。
        let deadline = ContinuousClock.now + .seconds(3)
        while model.items.first?.preview != "最新需求", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.items.count == 1); #expect(model.items.first?.preview == "最新需求")
        guard let id = model.items.first?.id else { return }
        model.select(id)
        let preview = try await store.preview(.delete([id])); _ = try await store.apply(preview.token)
        let deletionDeadline = ContinuousClock.now + .seconds(3)
        while !model.items.isEmpty, ContinuousClock.now < deletionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.items.isEmpty); #expect(model.detail == nil); #expect(model.selectedID == nil); #expect(model.image == nil)
    }
    /// 设置注册失败不落盘或显示成功；pause不被容量恢复覆盖。
    @Test func AC23_E04_registrationFailureAndIndependentPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let raw = RawBoard(); let board = MacPasteboardClient(access: raw); let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); defer { capture.stop() }
        let old = model.settings.shortcut; model.registerShortcut = { _ in false }
        model.updateSettings { $0.shortcut = .init(keyCode: 8, modifiers: 2304) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.settings.shortcut == old); #expect(try await store.settings().shortcut == old); #expect(model.message.contains("冲突"))
        model.updateSettings { $0.captureEnabled = false }; try await Task.sleep(for: .milliseconds(50))
        await capture.refreshCapacity()
        #expect(!capture.policy.captureEnabled); #expect(capture.state == "用户暂停")
    }
}
/// 可推进时钟只影响本测试实例，不改系统时间。
private final class ViewModelClock: ClipClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = SystemClock().now()
    func now() -> Instant { lock.withLock { value } }
    func advance(_ delta: Instant) { lock.withLock { value += delta } }
}
