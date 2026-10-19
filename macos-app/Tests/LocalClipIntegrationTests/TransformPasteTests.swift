// F16转换后粘贴：真实临时SQLite + fake剪贴板与目标应用，验证只写纯文本、失败不关面板、不新增历史，by AI.Coding。
import Foundation
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct TransformPasteTests {
    private struct Harness {
        let root: URL, store: HistoryStore, raw: RawBoard, apps: FakeApplications, capture: CaptureCoordinator, paste: PasteCoordinator
    }
    private func harness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try HistoryStore(location: root), raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications()
        let capture = CaptureCoordinator(board: board, store: store)
        return .init(root: root, store: store, raw: raw, apps: apps, capture: capture, paste: PasteCoordinator(board: board, applications: apps, store: store, capture: capture))
    }
    private func ingest(_ store: HistoryStore, _ text: String, at: Instant = SystemClock().now()) async throws -> ClipID {
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))], plainText: text)])), at: at) else { throw StoreError.notFound }
        return id
    }
    private func written(_ raw: RawBoard) -> [String] { raw.items.flatMap { $0.keys }.filter { $0 != NativePasteboardAccess.ownType } }

    /// AC3/AC6：直接粘贴写入转换后的纯文本并发送粘贴；自写不新增历史，原记录不变，by AI.Coding。
    @Test func directPasteWritesTransformedPlainTextOnly() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let json = #"{"b":1,"a":1.10}"#
        let id = try await ingest(h.store, json)
        try await h.capture.start()
        let result = await h.paste.perform(.init(ids: [id], format: .original, action: .directPaste, target: h.apps.remembered, transform: .formatJSON))
        #expect(result == .commandSent, "\(result)"); #expect(h.apps.events == 1)
        #expect(written(h.raw) == [SupportedType.string])
        #expect(h.raw.items[0][SupportedType.string] == Data("{\n  \"b\": 1,\n  \"a\": 1.10\n}".utf8))
        h.capture.tick(); try await Task.sleep(for: .milliseconds(150)); h.capture.stop()
        #expect(try await h.store.search(.init()).items.map(\.id) == [id])
        #expect(try await h.store.loadPayload(id: id, at: SystemClock().now()).items[0].representations.first?.data == Data(json.utf8))
    }

    /// 置顶面板在粘贴时重取前台目标；未置顶不重取，沿用打开面板时的目标。
    @Test func pinnedPasteRefreshesTarget() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let id = try await ingest(h.store, "pinned")
        try await h.capture.start(); defer { h.capture.stop() }
        let model = HistoryViewModel(store: h.store, capture: h.capture, paste: h.paste, derived: DerivedContentService(store: h.store))
        var refreshes = 0
        model.refreshPinnedTarget = { refreshes += 1; model.target = h.apps.remembered }
        // 切换应用后目标已被清空：置顶时仍能直接粘贴到当前前台应用。
        model.target = nil; model.pinned = true
        model.perform(action: .directPaste, ids: [id])
        let deadline = ContinuousClock.now + .seconds(3)
        while h.apps.events == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(refreshes == 1); #expect(h.apps.events == 1)
        model.pinned = false; model.target = nil
        model.perform(action: .directPaste, ids: [id])
        try await Task.sleep(for: .milliseconds(300))
        #expect(refreshes == 1); #expect(h.apps.events == 1)
    }

    /// AC4：转换失败不写剪贴板、不关闭面板、不激活目标，返回带行列的原因，by AI.Coding。
    @Test func failureKeepsClipboardAndPanel() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let id = try await ingest(h.store, "{\n  \"a\": oops\n}")
        h.raw.user("USER-CLIPBOARD"); let count = h.raw.count
        var closed = false; h.paste.closePanel = { _ in closed = true }
        let result = await h.paste.perform(.init(ids: [id], action: .directPaste, target: h.apps.remembered, transform: .formatJSON))
        guard case .failed(let message) = result else { Issue.record("Expected failure, got \(result)"); return }
        #expect(message.hasPrefix("不是有效 JSON") && message.contains("列"), "\(message)")
        #expect(!closed); #expect(h.apps.activations == 0); #expect(h.apps.events == 0)
        #expect(h.raw.count == count); #expect(h.raw.items[0][SupportedType.string] == Data("USER-CLIPBOARD".utf8))
    }

    /// AC8：默认操作为仅复制时只写剪贴板，不发送粘贴；多选先按换行合并再转换，by AI.Coding。
    @Test func copyOnlyAndMultiSelection() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let now = SystemClock().now()
        let first = try await ingest(h.store, "user_id", at: now), second = try await ingest(h.store, "max-retry-count", at: now + 1)
        let result = await h.paste.perform(.init(ids: [first, second], action: .copy, transform: .camelCase))
        #expect(result == .copied, "\(result)"); #expect(h.apps.events == 0)
        #expect(h.raw.items[0][SupportedType.string] == Data("userId\nmaxRetryCount".utf8))
    }

    /// AC1：Markdown代码块的语言来自离线识别，正文逐字不变，by AI.Coding。
    @Test func markdownUsesDetectedLanguage() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let swift = "import Foundation\nstruct Point { let x: Int; let y: Int }\nfunc distance(_ a: Point, _ b: Point) -> Double {\n    let dx = Double(a.x - b.x), dy = Double(a.y - b.y)\n    return (dx * dx + dy * dy).squareRoot()\n}"
        let id = try await ingest(h.store, swift)
        #expect(await h.paste.perform(.init(ids: [id], action: .copy, transform: .markdownCodeBlock)) == .copied)
        #expect(h.raw.items[0][SupportedType.string] == Data(("```swift\n" + swift + "\n```").utf8))
    }

    /// AC7：图片与文件记录不可转换，剪贴板保持原状，by AI.Coding。
    @Test func imagesAndFilesAreRejected() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        guard case .inserted(let image) = try await h.store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 4, height: 4))])])), at: SystemClock().now()),
              case .inserted(let file) = try await h.store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(URL(fileURLWithPath: "/tmp/a.txt").absoluteString.utf8))], plainText: "/tmp/a.txt")])), at: SystemClock().now() + 1) else { Issue.record("Fixture rejected"); return }
        h.raw.user("KEEP"); let count = h.raw.count
        #expect(await h.paste.perform(.init(ids: [image], action: .copy, transform: .uppercase)) == .failed("所选内容包含无文本项目，无法转换"))
        #expect(await h.paste.perform(.init(ids: [file], action: .copy, transform: .uppercase)) == .failed("文件记录无法转换"))
        #expect(h.raw.count == count)
    }

    /// ⌘T菜单：逐项判定适用，文件/图片/超限整体不可用并给出原因，by AI.Coding。
    @Test func menuAvailability() throws {
        func text(_ value: String) -> ClipboardPayload { .init([.init([.init(SupportedType.string, Data(value.utf8))], plainText: value)]) }
        let (json, none) = HistoryViewModel.transformAvailability([text(#"{"a": 1}"#)])
        #expect(none == nil); #expect(json.contains(.formatJSON) && json.contains(.markdownCodeBlock)); #expect(!json.contains(.base64Decode) && !json.contains(.stripPrompt))
        #expect(HistoryViewModel.transformAvailability([text("a"), text("b")]).0.contains(.sortLines))
        let file = ClipboardPayload([.init([.init(SupportedType.fileURL, Data(URL(fileURLWithPath: "/tmp/a").absoluteString.utf8))], plainText: "/tmp/a")])
        let image = ClipboardPayload([.init([.init(SupportedType.png, try ImageFixtures.image(width: 2, height: 2))])])
        for records in [[file], [image], [text("x"), image]] {
            let (available, reason) = HistoryViewModel.transformAvailability(records)
            #expect(available.isEmpty); #expect(reason == "所选内容不含文本，无法转换")
        }
        let (huge, tooLarge) = HistoryViewModel.transformAvailability([text(String(repeating: "a", count: TextTransform.byteLimit + 1))])
        #expect(huge.isEmpty); #expect(tooLarge == "内容过大（超过 4 MiB），无法转换")
    }

    /// 菜单实际分派走原有转换管线；⌥只复制，不按⌥仍直接粘贴，全程使用fake客户端，by AI.Coding。
    @Test(arguments: [false, true], [false, true]) func twoColumnMenuPreservesPasteAndOptionCopy(option: Bool, keyboard: Bool) async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let id = try await ingest(h.store, "user_id")
        let model = HistoryViewModel(store: h.store, capture: h.capture, paste: h.paste, derived: DerivedContentService(store: h.store))
        model.target = h.apps.remembered
        let menu = model.makeTransformMenu(ids: [id], available: [.camelCase], reason: nil)
        #expect(menu.window == nil)
        let count = h.raw.count
        if keyboard {
            menu.move(keyCode: 125)
            let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            #expect(menu.handleKey(enter))
        } else { menu.choose(.camelCase, modifiers: option ? [.option] : []) }
        let deadline = ContinuousClock.now + .seconds(3)
        while h.raw.count == count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // 直接粘贴包含写入后的异步目标恢复，等待fake收件而不启动真实应用。
        if !option {
            while h.apps.events == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(h.raw.count > count)
        #expect(h.raw.items.first?[SupportedType.string] == Data("userId".utf8))
        #expect(h.apps.events == (option ? 0 : 1))
        #expect(h.apps.activations == (option ? 0 : 1))
        #expect(try await h.store.loadPayload(id: id, at: SystemClock().now()).plainText == "user_id")
    }

    /// F18：AC1 SQL列表只写纯文本并按选择顺序；AC2换行与原有合并逐字节一致；AC3含图片时拒绝且剪贴板不变，by AI.Coding。
    @Test func joinStylesThroughPaste() async throws {
        let h = try harness(); defer { try? FileManager.default.removeItem(at: h.root) }
        let now = SystemClock().now()
        let ids = [try await ingest(h.store, "x", at: now), try await ingest(h.store, "O'Brien", at: now + 1), try await ingest(h.store, "y", at: now + 2)]
        #expect(await h.paste.perform(.init(ids: ids, action: .copy, join: .sqlList)) == .copied)
        #expect(written(h.raw) == [SupportedType.string])
        #expect(h.raw.items[0][SupportedType.string] == Data("'x', 'O''Brien', 'y'".utf8))
        var records: [ClipboardPayload] = []
        for id in ids { records.append(try await h.store.loadPayload(id: id, at: now)) }
        #expect(try OutputComposer.combine(records, format: .original, join: .newline) == OutputComposer.combine(records, format: .original))
        #expect(try OutputComposer.combine(records, format: .original).items[0].representations.map(\.type).contains(SupportedType.rtf))
        guard case .inserted(let image) = try await h.store.ingest(.init(payload: .init([.init([.init(SupportedType.png, try ImageFixtures.image(width: 4, height: 4))])])), at: now + 3) else { Issue.record("Fixture rejected"); return }
        let count = h.raw.count
        #expect(await h.paste.perform(.init(ids: [ids[0], image], action: .copy, join: .comma)) == .failed("所选内容包含无文本项目，无法合并"))
        #expect(h.raw.count == count)
    }
}
