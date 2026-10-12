// 2026-10-12审查整改：Enter默认、重新打开路由与使用后置前，by AI.Coding。
import AppKit
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

struct ReviewFixesTests {
    /// 新安装Enter直接粘贴、使用后置前；已保存的旧设置按原值解码。
    @Test func defaultsAndLegacyDecoding() throws {
        let fresh = SettingsSnapshot()
        #expect(fresh.defaultAction == .directPaste)
        #expect(fresh.moveUsedToFront)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]
        legacy["defaultAction"] = "copy"; legacy.removeValue(forKey: "moveUsedToFrontValue")
        let decoded = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.defaultAction == .copy)
        #expect(decoded.moveUsedToFront)
    }
    /// 同版本再次打开只显示面板；磁盘上换成新版本才接替；读不到磁盘版本不误杀。
    @MainActor @Test func reopenOnlyRelaunchesForNewVersion() {
        let running: [String: Any] = ["CFBundleShortVersionString": "0.3.12", "CFBundleVersion": "34"]
        #expect(!AppDelegate.installedVersionChanged(running: running, installed: running))
        #expect(AppDelegate.installedVersionChanged(running: running, installed: ["CFBundleShortVersionString": "0.3.13", "CFBundleVersion": "35"]))
        #expect(!AppDelegate.installedVersionChanged(running: running, installed: nil))
    }
    /// 使用记录置前并计数，名称与分类不变。
    @Test func touchMovesToFront() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let snapshot = { (text: String) in ClipboardSnapshot(payload: .init([.init([.init(SupportedType.string, Data(text.utf8))])])) }
        guard case .inserted(let old) = try await store.ingest(snapshot("old"), at: now),
              case .inserted(let new) = try await store.ingest(snapshot("new"), at: now + 1) else { Issue.record("插入失败"); return }
        try await store.renameClip(id: old, title: "kept")
        #expect(try await store.search(.init()).items.map(\.id) == [new, old])
        try await store.touch(ids: [old], at: now + 2)
        let items = try await store.search(.init()).items
        #expect(items.map(\.id) == [old, new])
        #expect(items[0].copyCount == 2 && items[0].title == "kept")
        // 分类视图按人工顺序排列；使用后在分类内同样置前。
        let category = try await store.createCategory(name: "touch-group", colorHex: "123456")
        let add = try await store.preview(.category([old, new], category.id, true)); _ = try await store.apply(add.token)
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [old, new])
        try await store.touch(ids: [new], at: now + 3)
        #expect(try await store.search(.init(categoryIDs: [category.id])).items.map(\.id) == [new, old])
    }
}

/// 鼠标/“始终显示滚动条”环境下的粗常驻滚动条被改为细悬浮样式，by AI.Coding。
@MainActor struct OverlayScrollerTests {
    @Test func legacyScrollerBecomesOverlay() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: .titled, backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasHorizontalScroller = true; scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
        let content = NSView(frame: .init(x: 0, y: 0, width: 2000, height: 200))
        scroll.documentView = content; window.contentView = scroll
        content.addSubview(OverlayScrollerStyle.Probe(frame: .zero))
        #expect(scroll.scrollerStyle == .overlay)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.horizontalScroller?.controlSize == .small)
    }
}
