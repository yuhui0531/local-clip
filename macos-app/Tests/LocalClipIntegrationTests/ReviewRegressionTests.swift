// 浏览保留、采集队列、键盘与转换安全回归，by AI.Coding。
import AppKit
import SwiftUI
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct ReviewUIRegressionTests {
    private func model(_ store: HistoryStore, _ raw: RawBoard) -> HistoryViewModel {
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        return HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    /// 拖动期间点击/键盘不会改变来源选择；结束后选择恢复，真实导出仍读取按下记录，by AI.Coding。
    @Test func dragFreezesSelectionUntilSessionEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        for text in ["drag-A", "drag-B", "drag-C"] { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: SystemClock().now()) }
        let model = model(store, raw); try await model.start(); model.capture.stop()
        try await until { model.items.count == 3 && !model.historyBusy }
        let source = model.items[1].id, other = model.items[0].id
        model.choose(source, modifiers: []); _ = model.prepareDrag(source)
        let access = try await store.exportAccess(id: source); model.registerDragAccess(access)
        model.choose(other, modifiers: []); model.select(other); model.navigate(1)
        #expect(model.selectedID == source); #expect(model.draggedIDs == [source])
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("new-during-drag".utf8))])])), at: SystemClock().now()+1000)
        try await until { model.items.first?.preview == "new-during-drag" && !model.historyBusy }
        #expect(model.selectedID == source)
        #expect(try access.itemData(index: 0, type: SupportedType.string) == Data("drag-B".utf8))
        model.finishDrag(cancelled: true)
        #expect(!model.dragActive); #expect(model.draggedIDs.isEmpty)
        #expect(throws: StoreError.notFound) { try access.itemData(index: 0, type: SupportedType.string) }
        model.choose(other, modifiers: []); #expect(model.selectedID == other)
    }
    /// 删除/到期在手势中冻结来源，结束后必须选择最近存活项；空历史必须清空详情，by AI.Coding。
    @Test(arguments: ["delete", "expire", "all"])
    func dragReconcilesRemovedSelection(removal: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), at = SystemClock().now()
        for index in 0..<3 {
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("removed-drag-\(index)".utf8))])])), at: at + Int64(index))
        }
        let model = model(store, RawBoard()); try await model.start(); model.capture.stop()
        try await until { model.items.count == 3 && !model.historyBusy }
        let source = model.items[1].id, neighbor = model.items[2].id
        if removal == "expire" {
            for id in model.items.map(\.id) where id != source {
                let preview = try await store.preview(.favorite(id, true)); _ = try await store.apply(preview.token)
            }
            try await until { model.items.filter { $0.id != source }.allSatisfy(\.isFavorite) && !model.historyBusy }
        }
        model.choose(source, modifiers: []); model.showingDetail = true; model.detailVisibilityChanged()
        try await until { model.detail?.summary.id == source }
        _ = model.prepareDrag(source)
        if removal == "expire" { _ = try await store.expire(at: at + 31 * 86_400_000) }
        else {
            let preview = try await store.preview(.delete(removal == "all" ? model.items.map(\.id) : [source]))
            _ = try await store.apply(preview.token)
        }
        try await until { !model.items.contains { $0.id == source } && !model.historyBusy }
        #expect(model.selectedID == source); #expect(model.draggedIDs == [source])
        model.finishDrag(cancelled: removal != "expire")
        #expect(!model.dragActive); #expect(model.draggedIDs.isEmpty)
        #expect(model.selectedID == (removal == "all" ? nil : neighbor))
        #expect(model.selectedIDs == (removal == "all" ? [] : [neighbor]))
        #expect(model.detail?.summary.id != source)
    }
    /// 没有滚动/分页的连续捕获只增长真实新项目；分页从超取截断点继续，不丢行。
    @Test(arguments: [80, 500])
    func repeatedCapturesDoNotPromotePrefetchedTail(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), at = SystemClock().now()
        for index in 0..<count { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("growth-\(index)".utf8))])])), at: at + Int64(index)) }
        let model = model(store, RawBoard()); try await model.start(); model.capture.stop()
        try await until { model.items.count == 50 && !model.historyBusy }
        let selected = model.items.first!.id
        for index in 0..<8 {
            let text = "growth-new-\(index)"
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: at + 1000 + Int64(index))
            try await until { model.items.first?.preview == text && !model.historyBusy }
            #expect(model.items.count == 51 + index); #expect(model.selectedID == selected)
        }
        let pagedCount = min(108, count + 8)
        model.loadMore(); try await until { model.items.count == pagedCount && !model.historyBusy }
        #expect(model.items.map(\.id) == Array(try await allIDs(store).prefix(pagedCount)))
        let tail = model.items.last!.id
        for index in 8..<11 {
            let text = "growth-new-\(index)"
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])), at: at + 1000 + Int64(index))
            try await until { model.items.first?.preview == text && !model.historyBusy }
            #expect(model.items.count == pagedCount + index - 7); #expect(model.items.contains { $0.id == tail }); #expect(model.selectedID == selected)
        }
        #expect(model.items.map(\.id) == Array(try await allIDs(store).prefix(pagedCount + 3)))
    }
    private func allIDs(_ store: HistoryStore) async throws -> [ClipID] {
        var request = SearchRequest(), result: [ClipID] = []
        repeat {
            let page = try await store.search(request); result += page.items.map(\.id); request.cursor = page.next
        } while request.cursor != nil
        return result
    }
    /// 正好50/100条的页尾选择，单次复制及隐藏期间超过一页的新复制都保留窗口与详情。
    @Test(arguments: [50, 100])
    func pageBoundaryAndHiddenBurstPreserveSelection(window: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), at = SystemClock().now()
        for index in 0..<200 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("boundary-\(index)".utf8))])])), at: at + Int64(index)) }
        let model = model(store, RawBoard()); try await model.start(); model.capture.stop()
        try await until { model.items.count == 50 && !model.historyBusy }
        if window == 100 { model.loadMore(); try await until { model.items.count == 100 && !model.historyBusy } }
        let oldWindow = Set(model.items.map(\.id)), selected = model.items[window - 1].id
        model.select(selected); model.showingDetail = true; model.detailVisibilityChanged()
        try await until { model.detail?.summary.id == selected }
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("boundary-new".utf8))])])), at: at + 1000)
        try await until { model.items.first?.preview == "boundary-new" && !model.historyBusy }
        #expect(oldWindow.isSubset(of: Set(model.items.map(\.id))))
        #expect(model.selectedID == selected); #expect(model.selectedIDs.contains(selected)); #expect(model.detail?.summary.id == selected)
        model.panelVisibilityChanged(false)
        let previousCount = model.items.count
        for index in 0..<75 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("burst-\(index)".utf8))])])), at: at + 2000 + Int64(index)) }
        model.panelVisibilityChanged(true)
        try await until { model.items.first?.preview == "burst-74" && !model.historyBusy }
        #expect(model.items.count >= previousCount + 75)
        #expect(model.selectedID == selected); #expect(model.detail?.summary.id == selected)
        let deletion = try await store.preview(.delete([selected])); _ = try await store.apply(deletion.token)
        try await until { !model.items.contains { $0.id == selected } && !model.historyBusy }
        #expect(model.selectedID != selected); #expect(!model.selectedIDs.contains(selected))
    }
    /// 三页浏览与详情在空维护、后台采集及无关收藏提交后仍保持。
    @Test func loadedWindowSelectionAndDetailSurviveChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        for index in 0..<130 { _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("history-\(index)".utf8))])])), at: SystemClock().now() + Int64(index)) }
        let model = model(store, RawBoard()); try await model.start(); model.capture.stop()
        try await until { model.items.count == 50 && !model.historyBusy }
        model.loadMore(); try await until { model.items.count == 100 && !model.historyBusy }
        model.loadMore(); try await until { model.items.count == 130 && !model.historyBusy }
        let selected = model.items[120].id
        model.select(selected); model.showingDetail = true; model.detailVisibilityChanged()
        try await until { model.detail?.summary.id == selected }
        await model.maintenance()
        #expect(model.items.count == 130); #expect(model.selectedID == selected); #expect(model.detail?.summary.id == selected)
        _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("unrelated-new-copy".utf8))])])), at: SystemClock().now() + 1000)
        try await until { model.items.first?.preview == "unrelated-new-copy" && !model.historyBusy }
        #expect(model.items.count >= 130); #expect(model.selectedID == selected); #expect(model.detail?.summary.id == selected)
        let favorite = try await store.preview(.favorite(model.items[0].id, true)); _ = try await store.apply(favorite.token)
        try await until { model.items.first?.isFavorite == true && !model.historyBusy }
        #expect(model.selectedID == selected); #expect(model.detail?.summary.id == selected)
        let deletion = try await store.preview(.delete([selected])); _ = try await store.apply(deletion.token)
        try await until { !model.items.contains { $0.id == selected } && !model.historyBusy }
        #expect(model.selectedID != model.items.first?.id); #expect(!model.selectedIDs.contains(selected)); #expect(model.detail?.summary.id != selected)
    }
    /// 不变策略和UI偏好保存都不能清空队列；真正暂停清空旧复制。
    @Test func queuedCopiesSurvivePolicyRefreshAndPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard(), model = model(store, raw)
        try await model.start(); model.capture.stop()
        for text in ["A", "B", "C"] { raw.user(text); model.capture.tick() }
        model.capture.updatePolicy(model.capture.policy)
        model.updateSettings { $0.panelHeight = 480 }
        let deadline = ContinuousClock.now + .seconds(15)
        while try await store.search(.init()).items.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(Set(try await store.search(.init()).items.map(\.preview)) == Set(["A", "B", "C"]))
        try await until { model.settings.panelHeight == 480 }
        for text in ["paused-D", "paused-E"] { raw.user(text); model.capture.tick() }
        model.capture.requestPause()
        var policy = model.capture.policy; policy.captureEnabled = false; model.capture.updatePolicy(policy)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await store.search(.init("paused-")).items.isEmpty)
    }
    /// 设置保存中的后续编辑合并为最后值，不丢滑块结尾或其他开关。
    @Test func concurrentSettingsKeepFinalValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), model = model(store, RawBoard())
        try await model.start(); model.capture.stop()
        model.updateSettings { $0.panelHeight = 360 }
        model.updateSettings { $0.panelHeight = 440 }
        model.updateSettings { $0.panelHeight = 480; $0.captureSounds = true }
        try await until { model.settings.panelHeight == 480 && model.settings.captureSounds }
        #expect(try await store.settings().panelHeight == 480); #expect(try await store.settings().captureSounds)
    }
    /// 恢复按钮清除定时暂停并持久化；不能只是把记录开关改成开启，by AI.Coding。
    @Test func resumeRecordingClearsTimedPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), model = model(store, RawBoard())
        try await model.start(); defer { model.capture.stop() }
        model.updateSettings { $0.pauseUntil = SystemClock().now() + 60_000 }
        try await until { model.settings.pauseUntil != nil }
        #expect(model.recordingPaused)
        model.toggleRecording()
        try await until { model.settings.captureEnabled && model.settings.pauseUntil == nil }
        #expect(!model.recordingPaused)
        let saved = try await store.settings()
        #expect(saved.captureEnabled && saved.pauseUntil == nil)
        model.toggleRecording()
        try await until { !model.settings.captureEnabled }
        #expect(model.recordingPaused)
        model.toggleRecording()
        try await until { model.settings.captureEnabled }
        model.updateSettings { $0.pauseUntil = SystemClock().now() - 1 }
        try await until { model.settings.pauseUntil != nil }
        #expect(!model.recordingPaused)
        model.query = "keep my search"; model.favorites = true; model.kind = .image
        model.sourceFilter = "com.example"; model.dateFilterEnabled = true
        model.categoryID = "category"; model.categoryFilters = ["category"]
        model.clearHistoryFilters()
        #expect(model.query == "keep my search")
        #expect(!model.favorites && model.kind == nil && model.activeCategories.isEmpty)
        #expect(model.sourceFilter == nil && !model.dateFilterEnabled)
    }
    /// 中文候选中的 Esc 交给输入法，普通 Esc 仍关闭面板，by AI.Coding。
    @Test func searchEscapeRespectsMarkedText() {
        var closes = 0
        let field = SearchField(text: .constant(""), focus: UUID(), onChange: {}, onNavigate: { _ in }, onEnter: {}, onEscape: { closes += 1 })
        let coordinator = field.makeCoordinator(), editor = NSTextView(), control = NSSearchField()
        editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closes == 0)
        editor.unmarkText()
        #expect(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closes == 1)
    }
    /// 空输入也不删除历史，IME和原生文本编辑仍由field editor处理。
    @Test func backspaceInEmptySearchNeverDeletesRecord() {
        let field = SearchField(text: .constant(""), focus: UUID(), onChange: {}, onNavigate: { _ in }, onEnter: {}, onEscape: {})
        let coordinator = field.makeCoordinator(), editor = NSTextView(), control = NSSearchField()
        for text in ["ab", "a", "", ""] {
            editor.string = text
            #expect(!coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        }
        #expect(!coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.deleteForward(_:))))
    }
    /// 终端应用、嵌入式终端和只有窗口角色的Zed不能转为文件正文。
    @Test func terminalsAndUnknownWindowsNeverConvertCodeFiles() {
        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "org.alacritty", "io.alacritty"] {
            #expect(MacApplicationClient.classifyTextMetadata(role: "AXTextArea", subrole: "", editable: true, selectedRangeSettable: true, bundleID: bundle) == .unknown)
        }
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXTextArea", subrole: "", editable: true, selectedRangeSettable: true, bundleID: "com.microsoft.VSCode", terminalContext: true) == .unknown)
        #expect(MacApplicationClient.classifyTextMetadata(role: "AXTextArea", subrole: "", editable: true, selectedRangeSettable: true, bundleID: "com.microsoft.VSCode") == .text)
        #expect(MacApplicationClient.isTerminalMetadata("xterm terminal")); #expect(MacApplicationClient.isTerminalMetadata("集成终端"))
        #expect(!MacApplicationClient.isTerminalMetadata("editor"))
    }
    /// 失败回退仍发送原文件并给出原因，不虚报目标已接收。
    @Test func codeReadFailureHasVisibleReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("binary.kt"); try Data([0,1]).write(to: file)
        var settings = SettingsSnapshot(); settings.smartCodeFilePaste = true
        let store = try HistoryStore(location: root.appendingPathComponent("store"), initialSettings: settings)
        guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.fileURL, Data(file.absoluteString.utf8))])])), at: SystemClock().now()) else { Issue.record("fixture"); return }
        let raw = RawBoard(), board = MacPasteboardClient(access: raw), apps = FakeApplications(); apps.targetKind = .text
        let capture = CaptureCoordinator(board: board, store: store), paste = PasteCoordinator(board: board, applications: apps, store: store, capture: capture)
        #expect(await paste.perform(.init(ids: [id], action: .directPaste, target: apps.remembered)) == .commandSent)
        #expect(paste.smartPasteNotice?.contains("编码") == true); #expect(raw.items.first?[SupportedType.fileURL] != nil)
    }
}
struct ReviewCodeRegressionTests {
    /// 常见脚本/配置及合法换页、ESC字符不误拒，NUL仍被二进制保护拒绝。
    @Test func commonCodeNamesAndTextControls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "text\u{0C}page\u{1B}[0m\n"
        for name in ["a.kt", "a.vue", "Makefile", "a.ps1", "a.graphql", "a.ini", "Dockerfile.dev", "a.m"] {
            let file = root.appendingPathComponent(name); try Data(text.utf8).write(to: file)
            #expect(try CodeFileReader.read([file]) == text)
        }
        let file = root.appendingPathComponent("a.py"); try Data([0]).write(to: file)
        #expect(throws: CodeFileReadError.binaryOrEncoding) { try CodeFileReader.read([file]) }
    }
    @Test func URLsAreNeverDetectedAsCode() async {
        #expect(await SyntaxHighlighter.shared.highlight("https://example.invalid/path?a=1&b=2#section") == nil)
        #expect(await SyntaxHighlighter.detail.highlight("https://example.invalid/path?a=1&b=2#section") == nil)
    }
    /// 截图样本：路径曾被当成Ruby/Swift正则字面量，卡片标题显示成语言名，by AI.Coding。
    @Test func pathsAndChineseProseAreNeverDetectedAsCode() async {
        let path = "/Users/ronny/VscodeProjects/rea/macos-app/docs/reviews/LocalClip_Comprehensive_Review_2026-10-14.md"
        for text in [path, "请根据review comments **\(path) 进行修复。**  注意，切记功能", "See /usr/local/bin/foo for details"] {
            #expect(await SyntaxHighlighter.shared.highlight(text) == nil, "\(text)")
            #expect(await SyntaxHighlighter.shared.guess(of: text).language == nil, "\(text)")
        }
        #expect(await SyntaxHighlighter.shared.guess(of: "// 获取用户列表\nfunction getUsers() { return api.get('/users'); }").language == "javascript")
    }
}
