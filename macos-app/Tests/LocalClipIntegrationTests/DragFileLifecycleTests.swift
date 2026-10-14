// LC-R01：取消、内部分类、外部路径保留与改名硬链接，全部使用测试库，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct DragFileLifecycleTests {
    /// 保留每项真实promise身份；注册延迟类型后，混合多选的正文、文件名和原图不能串项，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func nativeProvidersAndLazyDataKeepMixedItemOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let png = try ImageFixtures.image(width: 24, height: 16)
        let jpeg = try ImageFixtures.image(width: 16, height: 24, type: SupportedType.jpeg)
        let fixtures = [Representation(SupportedType.string, Data("text-first".utf8)), .init(SupportedType.png, png), .init(SupportedType.jpeg, jpeg)]
        var ids: [ClipID] = []
        for (index, fixture) in fixtures.enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([fixture])])), at: now + Int64(index)) else { throw StoreError.notFound }
            ids.append(id)
        }
        let writers = try await ContentExportProvider.writers(ids: ids, store: store, token: "mixed", register: { _ in })
        #expect(writers.count == 3 && writers.allSatisfy { $0 is NSFilePromiseProvider })
        let board = NSPasteboard(name: .init("local.localclip.native-lazy." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(writers))
        try ContentExportProvider.installImageDataProviders(writers, on: board)
        #expect(try await store.dragFilesBytes() == 0)
        #expect((board.readObjects(forClasses: [NSFilePromiseReceiver.self]) ?? []).count == 3)
        let items = try #require(board.pasteboardItems)
        #expect(items[0].string(forType: .string) == "text-first")
        for index in 1...2 {
            let path = try #require(items[index].string(forType: .fileURL).flatMap(URL.init(string:)))
            #expect(try Data(contentsOf: path) == fixtures[index].data)
            #expect(path.lastPathComponent.hasSuffix(index == 1 ? "-2.png" : "-3.jpg"))
            #expect(items[index].data(forType: .init(fixtures[index].type)) == fixtures[index].data)
            #expect(items[index].string(forType: .init(HistoryViewModel.categoryDragType)) == "mixed")
        }
        #expect(try await store.integrityCheck())
    }

    /// URL兑现与取消并发时，取消必须拿到正在新建的路径，不能漏清理或复活旧会话，by AI.Coding。
    @Test func cancellationWaitsForInFlightMaterialization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let bytes = try ImageFixtures.image(width: 24, height: 16)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        let access = try await store.exportAccess(id: id), session = ImageDragSession()
        let written = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let request = Task.detached {
            defer { written.signal() }
            return try session.fileURL(key: "request") {
                let file = try access.materializeDragFile(index: 0, type: SupportedType.png, fileName: "race.png")
                written.signal(); release.wait()
                return file
            }
        }
        // 所有阻塞均在后台；不让测试主线程等待自身要释放的信号。
        let cancellation = Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
                DispatchQueue.global().async {
                    _ = written.wait(timeout: .now() + 5)
                    continuation.resume(returning: session.finish(keepFiles: false))
                }
            }
        }
        let unblock = Task.detached { try await Task.sleep(for: .milliseconds(50)); release.signal() }
        let path = try await request.value, cleanup = await cancellation.value
        try await unblock.value
        #expect(cleanup == [path])
        #expect(try Data(contentsOf: path) == bytes)
        try await store.removeDragFiles(cleanup)
        #expect(try await store.dragFilesBytes() == 0)
        #expect(throws: StoreError.notFound) { try session.fileURL(key: "late") { try access.materializeDragFile(index: 0, type: SupportedType.png, fileName: "late.png") } }
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).items[0].representations[0].data == bytes)
        #expect(try await store.integrityCheck())
    }

    /// 延迟回调可能在会话结束后到达：取消拒绝新文件，外部成功保留接收路径，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"), arguments: [false, true])
    func lateFileURLRequestRespectsSessionOutcome(accepted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let bytes = try ImageFixtures.image(width: 24, height: 16)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        var session: ImageDragSession?
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "late", register: { _ in }, registerSession: { session = $0 })
        let board = NSPasteboard(name: .init("local.localclip.late-image." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(writers))
        try ContentExportProvider.installImageDataProviders(writers, on: board)
        #expect(try #require(session).finish(keepFiles: accepted).isEmpty)
        let url = board.string(forType: .fileURL).flatMap(URL.init(string:))
        if accepted {
            #expect(try Data(contentsOf: #require(url)) == bytes)
        } else {
            #expect(url == nil)
            #expect(try await store.dragFilesBytes() == 0)
        }
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).items[0].representations[0].data == bytes)
    }

    /// 多选合计超过单文件导出上限仍可声明全部项目；起手不能驻留/写出原图，by AI.Coding。
    @Test func largeSelectionPreparationRetainsEveryItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        var ids: [ClipID] = []
        for value: UInt8 in [1, 2] {
            let bytes = Data(repeating: value, count: 30 * Int(MiB))
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
            ids.append(id)
        }
        let writers = try await ContentExportProvider.writers(ids: ids, store: store, token: "large", register: { _ in })
        #expect(writers.count == 2)
        #expect(writers.allSatisfy { ContentExportProvider.promiseProvider(for: $0)?.fileType == SupportedType.png })
        #expect(try await store.dragFilesBytes() == 0)
        #expect(try await store.integrityCheck())
    }

    /// LC-R01：声明拖放类型和读取内部令牌不能读取/写出原图；目标索取URL时才生成文件，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func preparationAndInternalTokenDoNotMaterializeImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let bytes = try ImageFixtures.image(width: 24, height: 16)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "internal", register: { _ in })
        #expect(try await store.dragFilesBytes() == 0)
        let board = NSPasteboard(name: .init("local.localclip.deferred-image." + UUID().uuidString))
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(writers))
        #expect(writers.allSatisfy { $0 is NSFilePromiseProvider })
        try ContentExportProvider.installImageDataProviders(writers, on: board)
        #expect(try await store.dragFilesBytes() == 0)
        #expect(board.string(forType: .init(HistoryViewModel.categoryDragType)) == "internal")
        #expect(try await store.dragFilesBytes() == 0)
        let received = try #require(board.string(forType: .fileURL).flatMap(URL.init(string:)))
        #expect(try Data(contentsOf: received) == bytes)
        #expect(board.data(forType: .png) == bytes)
    }
    /// 取消/分类只删除本次新建路径；旧外部引用在两种情况下都保留。
    @Test(arguments: ["cancel", "category", "existing-cancel", "existing-category"])
    func sessionCleanupPreservesExternalReferences(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let bytes = try ImageFixtures.image(width: 12, height: 12)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        let category = try await store.createCategory(name: "Drag cleanup", colorHex: "34C759")
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        let until = ContinuousClock.now + .seconds(5)
        while (model.items.isEmpty || model.categories.isEmpty || model.historyBusy), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.items.contains { $0.id == id })
        var oldURL: URL?
        if mode.hasPrefix("existing") {
            let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "external", register: { _ in })
            let raw = try #require(writers.first?.pasteboardPropertyList(forType: .fileURL) as? Data)
            oldURL = try #require(URL(dataRepresentation: raw, relativeTo: nil))
        }
        let token = model.prepareDrag(id)
        await model.waitForDragCleanup()
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: token, register: model.registerDragAccess, registerSession: model.registerDragSession)
        let raw = try #require(writers.first?.pasteboardPropertyList(forType: .fileURL) as? Data)
        let path = try #require(URL(dataRepresentation: raw, relativeTo: nil))
        #expect(try Data(contentsOf: path) == bytes)
        if mode.hasSuffix("category") { #expect(model.dropIntoCategory(token, categoryID: category.id)) }
        model.finishDrag(cancelled: mode.hasSuffix("cancel"))
        await model.waitForDragCleanup()
        if let oldURL {
            #expect(try Data(contentsOf: oldURL) == bytes)
            #expect(try await store.dragFilesBytes() > 0)
        } else {
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try await store.dragFilesBytes() == 0)
        }
        #expect(try await store.loadPayload(id: id, at: SystemClock().now()).items[0].representations[0].data == bytes)
    }

    /// 同一图片改名不重复分配物理块；取消新链接不破坏原外部路径。
    @Test func renamedImageSharesInode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        let bytes = try ImageFixtures.image(width: 12, height: 12)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, bytes)])])), at: SystemClock().now()) else { throw StoreError.notFound }
        let first = try await store.writeTrackedDragFile(bytes, id: id, fileName: "first.png")
        let originalBytes = try await store.dragFilesBytes()
        let renamed = try await store.writeTrackedDragFile(bytes, id: id, fileName: "renamed.png")
        #expect(try await store.dragFilesBytes() == originalBytes)
        let fm = FileManager.default
        #expect(first.created && renamed.created)
        #expect(try fm.attributesOfItem(atPath: first.url.path)[.systemFileNumber] as? NSNumber == fm.attributesOfItem(atPath: renamed.url.path)[.systemFileNumber] as? NSNumber)
        #expect(try await store.writeTrackedDragFile(bytes, id: id, fileName: "first.png").created == false)
        try await store.removeDragFiles([renamed.url])
        #expect(try Data(contentsOf: first.url) == bytes)
        #expect(try await store.integrityCheck())
    }
}
