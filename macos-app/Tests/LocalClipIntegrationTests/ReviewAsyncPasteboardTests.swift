// 异步读取的暂停世代及真实私有剪贴板回归，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor private final class SuspendedPasteboardAccess: PasteboardAccess {
    var count = 1
    var value = "old"
    var continuation: CheckedContinuation<PasteboardBody, Never>?
    var body: PasteboardBody?
    var types: [[String]]? { [[SupportedType.string]] }
    func data(item: Int, type: String) -> Data? { Data(value.utf8) }
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool { false }
    func readBody(types: [[String]], expectedCount: Int) async -> PasteboardBody {
        body = PasteboardBody.readApproved(types: types, expectedCount: expectedCount, currentCount: { count }, currentTypes: { self.types }, data: data)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: body!); continuation = nil; body = nil }
}

@MainActor private final class LateChangingPasteboardAccess: PasteboardAccess {
    var count = 1
    let marker: String
    var changed = false
    var bodyReads = 0
    init(marker: String) { self.marker = marker }
    var types: [[String]]? { [[SupportedType.string] + (changed ? [marker] : [])] }
    func data(item: Int, type: String) -> Data? { bodyReads += 1; return Data("synthetic-sensitive".utf8) }
    func write(_ payload: ClipboardPayload, fingerprint: String) -> Bool { false }
    func readBody(types: [[String]], expectedCount: Int) async -> PasteboardBody {
        // 模拟主线程批准以后、工人重开以前的新一次敏感复制。
        changed = true; count += 1
        return PasteboardBody.readApproved(types: types, expectedCount: expectedCount, currentCount: { count }, currentTypes: { self.types }, data: data)
    }
}

private final class CountingBodyProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); count += 1; lock.unlock()
        item.setData(Data("synthetic-sensitive".utf8), forType: type)
    }
}

@MainActor struct ReviewAsyncPasteboardTests {
    @Test(arguments: SupportedType.markers.sorted())
    func lateSensitiveChangeNeverReadsBody(marker: String) async {
        let access = LateChangingPasteboardAccess(marker: marker)
        let client = MacPasteboardClient(access: access)
        if case .skipped(.sensitive, 2) = await client.captureAsync(after: 0, policy: .init()) {} else { Issue.record("新敏感世代未过滤") }
        #expect(access.bodyReads == 0)
    }
    /// 当前声明即使计数未变也必须重新核对；读第一表示时变化不能再读第二表示。
    @Test func workerChecksDeclarationsAndEveryRepresentation() {
        var count = 1, reads = 0
        for marker in SupportedType.markers {
            let body = PasteboardBody.readApproved(types: [[SupportedType.string]], expectedCount: 1, currentCount: { count }, currentTypes: { [[SupportedType.string, marker]] }) { _, _ in reads += 1; return Data() }
            if case .failure(.sensitive) = body {} else { Issue.record("工人未复查敏感标记") }
        }
        let mismatched = PasteboardBody.readApproved(types: [[SupportedType.string]], expectedCount: 1, currentCount: { count }, currentTypes: { [[SupportedType.html]] }) { _, _ in reads += 1; return Data() }
        if case .failure(.changedDuringRead) = mismatched {} else { Issue.record("当前类型不匹配仍读取") }
        #expect(reads == 0)
        let types = [[SupportedType.html, SupportedType.string]]
        let changed = PasteboardBody.readApproved(types: types, expectedCount: 1, currentCount: { count }, currentTypes: { types }) { _, _ in
            reads += 1; count += 1; return Data("first-generation".utf8)
        }
        if case .failure(.changedDuringRead) = changed {} else { Issue.record("世代变化仍发布") }
        #expect(reads == 1)
    }
    /// 原生命名板在预检后换代，延迟数据provider不能被后台读取触发。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func nativeWorkerRejectsChangedBoardBeforeProviderRead() async {
        let native = NSPasteboard(name: .init("local.localclip.review-late." + UUID().uuidString))
        defer { native.releaseGlobally() }
        let old = NSPasteboardItem(); old.setString("approved-old", forType: .init(SupportedType.string))
        native.clearContents(); #expect(native.writeObjects([old]))
        let access = NativePasteboardAccess(native), count = native.changeCount
        let types = native.pasteboardItems!.map { $0.types.map(\.rawValue) }
        let provider = CountingBodyProvider(), sensitive = NSPasteboardItem()
        #expect(sensitive.setDataProvider(provider, forTypes: [.init(SupportedType.string)]))
        sensitive.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        native.clearContents(); #expect(native.writeObjects([sensitive]))
        let body = await access.readBody(types: types, expectedCount: count)
        if case .failure(.changedDuringRead) = body {} else { Issue.record("原生工人读取了新世代") }
        #expect(provider.reads == 0)
        if case .skipped(.sensitive, _) = await MacPasteboardClient(access: access).captureAsync(after: count, policy: .init()) {} else { Issue.record("重试未过滤敏感标记") }
        #expect(provider.reads == 0)
    }
    /// 等待正文期间主线程仍可暂停；恢复也不能提交暂停前的读取结果。
    @Test func pauseInvalidatesSuspendedReadAndResumeAcceptsNewCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), access = SuspendedPasteboardAccess()
        let board = MacPasteboardClient(access: access), capture = CaptureCoordinator(board: board, store: store)
        try await capture.start(); capture.stop()
        access.count += 1
        let read = Task { await capture.poll() }
        while access.continuation == nil { await Task.yield() }
        capture.requestPause(); capture.updatePolicy(capture.policy)
        access.finish(); await read.value
        #expect(try await store.search(.init()).items.isEmpty)
        access.count += 1; access.value = "new-after-resume"
        let next = Task { await capture.poll() }
        while access.continuation == nil { await Task.yield() }
        access.finish(); await next.value
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.map(\.preview) == ["new-after-resume"])
        capture.stop()
    }
    /// 原生后台IPC读回全部项目/表示，只操作独立命名板，不触碰通用剪贴板。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func nativeBackgroundReadPreservesAllRepresentations() async throws {
        let native = NSPasteboard(name: .init("local.localclip.review-async." + UUID().uuidString))
        defer { native.releaseGlobally() }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(Data("中文\ntext".utf8), forType: .init(SupportedType.string))
        first.setData(Data("<b>中文</b>".utf8), forType: .init(SupportedType.html))
        second.setData(Data([1,2,3]), forType: .init(SupportedType.png))
        second.setData(Data([4,5,6]), forType: .init(SupportedType.tiff))
        native.clearContents(); #expect(native.writeObjects([first, second]))
        let board = MacPasteboardClient(access: NativePasteboardAccess(native))
        guard case .snapshot(let snapshot) = await board.captureAsync(after: -1, policy: .init()) else { Issue.record("native read unavailable"); return }
        #expect(snapshot.payload.items.count == 2)
        #expect(snapshot.payload.items[0].representations.first { $0.type == SupportedType.html }?.data == Data("<b>中文</b>".utf8))
        #expect(snapshot.payload.items[1].representations.first { $0.type == SupportedType.png }?.data == Data([1,2,3]))
        #expect(snapshot.payload.items[1].representations.first { $0.type == SupportedType.tiff }?.data == Data([4,5,6]))
    }
    /// 另一进程在私有命名板写入一万次时由生产 captureAsync 读取并核对守恒，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"
                   && ProcessInfo.processInfo.environment["LOCALCLIP_PASTEBOARD_SOAK"] == "1"))
    func nativeCaptureSurvivesCrossProcessTenThousandWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boardName = "local.localclip.review-soak." + UUID().uuidString
        let native = NSPasteboard(name: .init(boardName))
        defer { native.releaseGlobally() }
        native.clearContents()
        let client = MacPasteboardClient(access: NativePasteboardAccess(native))
        let store = try HistoryStore(location: root.appendingPathComponent("store"))
        let policy = try await store.settings()
        let source = try #require(Bundle.module.url(forResource: "PasteboardSoakWriter", withExtension: "m", subdirectory: "Fixtures"))
        let executable = root.appendingPathComponent("pasteboard-soak-writer")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-fmodules", "-fmodules-cache-path=\(root.appendingPathComponent("clang-cache").path)",
                              "-framework", "Carbon", source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        #expect(compiler.terminationStatus == 0)

        let writer = Process(), output = Pipe(), errors = Pipe()
        writer.executableURL = executable
        writer.arguments = [boardName, "10000"]
        writer.standardOutput = output; writer.standardError = errors
        try writer.run()
        var baseline = native.changeCount
        var savedInputs = Set<Int>(), savedClipIDs = Set<ClipID>(), captureSkipEvents = 0
        func accept(_ snapshot: ClipboardSnapshot) async throws {
            guard let representation = snapshot.payload.items.first?.representations.first(where: { $0.type == SupportedType.string }),
                  let value = String(data: representation.data, encoding: .utf8), value.hasPrefix("LOCALCLIP-SOAK-"),
                  let input = Int(value.dropFirst("LOCALCLIP-SOAK-".count)), (0..<10_000).contains(input) else {
                Issue.record("named-board capture returned malformed content"); return
            }
            guard savedInputs.insert(input).inserted else { Issue.record("a soak input was captured twice"); return }
            switch try await store.ingest(ContentDecoder.decode(snapshot), at: snapshot.capturedAt) {
            case .inserted(let id): savedClipIDs.insert(id)
            case .deduplicated: Issue.record("distinct soak input was deduplicated")
            case .skipped: Issue.record("valid soak entry was rejected by storage")
            }
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while writer.isRunning && ContinuousClock.now < deadline {
            switch await client.captureAsync(after: baseline, policy: policy) {
            case .noChange:
                try await Task.sleep(for: .milliseconds(1))
            case .skipped(_, let count):
                baseline = count; captureSkipEvents += 1
            case .snapshot(let snapshot):
                baseline = snapshot.changeCount
                try await accept(snapshot)
            }
        }
        if writer.isRunning { writer.terminate(); Issue.record("writer exceeded the 60-second soak limit") }
        writer.waitUntilExit()
        let writerOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let writerError = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if writer.terminationStatus != 0 { Issue.record("writer failed: \(writerError)") }
        #expect(writer.terminationStatus == 0)
        #expect(writerOutput == "10000")
        switch await client.captureAsync(after: baseline, policy: policy) {
        case .snapshot(let snapshot): try await accept(snapshot)
        case .skipped: captureSkipEvents += 1
        case .noChange: break
        }
        let writerInputs = Set(0..<10_000)
        let neverCapturedInputs = writerInputs.subtracting(savedInputs)
        print("R11 named-pasteboard soak: writes=10000 uniqueInputsCaptured=\(savedInputs.count) captureSkipEvents=\(captureSkipEvents) writesNeverCaptured=\(neverCapturedInputs.count)")
        #expect(savedInputs.isSubset(of: writerInputs))
        #expect(savedInputs.count + neverCapturedInputs.count == writerInputs.count)
        #expect(savedClipIDs.count == savedInputs.count)
        #expect(try await store.search(.init("LOCALCLIP-SOAK-")).items.count == min(savedInputs.count, 50))
    }
}
