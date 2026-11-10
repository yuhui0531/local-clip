// 管理表格行高回归：使用合成记录和始终隐藏的窗口，不接触真实桌面或剪贴板，by AI.Coding。
import AppKit
import SwiftUI
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

@MainActor struct ManagerTableLayoutTests {
    /// 条件等待必须有结果断言，不能将超时当作测试通过。
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// 冷加载、离屏单元格重建、窄窗口和翻页都不能再次改变同一页的总高度。
    @Test(arguments: [true, false])
    func scrollRangeRemainsStableAcrossMaterializationAndPaging(images: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        var ids: [ClipID] = []
        for index in 0..<68 {
            let data = images
                ? try ImageFixtures.image(width: 80 + index, height: index.isMultiple(of: 2) ? 20 : 180)
                : Data(("长标题 \(index) " + String(repeating: "名称", count: 40) + "\n第一行摘要\n第二行摘要").utf8)
            guard case .inserted(let id) = try await store.ingest(.init(payload: .init([.init([
                .init(images ? SupportedType.png : SupportedType.string, data)
            ])])), at: now - Int64(index)) else { throw StoreError.ioFailure }
            ids.append(id)
        }
        // 两个分类与 +N 同时出现，验证统一行高仍能容纳已有分类布局。
        for name in ["较长分类名称甲", "分类乙", "分类丙"] {
            let category = try await store.createCategory(name: name, colorHex: "007AFF")
            _ = try await store.apply(try await store.preview(.category(ids, category.id, true)).token)
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let history = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        try await history.start(); capture.stop()
        let model = HistoryManagerModel(history: history); model.start()
        defer { model.stop() }
        try await until { model.rows.count == 50 && !model.loading }
        let host = NSHostingView(rootView: HistoryManagerView(model: model, history: history)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1500, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func tables(_ view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
        }
        host.layoutSubtreeIfNeeded()
        try await until { tables(host).contains { $0.numberOfColumns == 6 && $0.numberOfRows == 50 } }
        let table = try #require(tables(host).first { $0.numberOfColumns == 6 })
        let scroll = try #require(table.enclosingScrollView)
        // Table 先发布行数再异步挂接单元格；等待首屏实际出现后再开始滚动测试。
        try await until { table.view(atColumn: 1, row: 0, makeIfNecessary: false) != nil }
        host.layoutSubtreeIfNeeded()
        let firstPageHeight = table.frame.height
        for width in [1500.0, Double(HistoryManagerWindow.minimumWidth)] {
            window.setContentSize(.init(width: width, height: 900))
            for row in [37, 49, 0, 25] {
                table.scrollRowToVisible(row)
                // 与实际调用栈一致，让离屏单元格实体化；不修改表格辅助功能行为。
                for index in 0..<table.numberOfRows {
                    for column in 0..<table.numberOfColumns { _ = table.view(atColumn: column, row: index, makeIfNecessary: true) }
                }
                host.layoutSubtreeIfNeeded()
                let offset = scroll.contentView.bounds.minY
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                #expect(abs(table.frame.height - firstPageHeight) < 0.5)
                #expect(abs(scroll.contentView.bounds.minY - offset) < 0.5)
                #expect(table.rect(ofRow: row).height == 56)
                // 原生单元格自然高度含上下留白；名称和分类均须完整容纳在实际行内。
                for column in [1, 2] {
                    let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true))
                    #expect(cell.fittingSize.height <= 56.5)
                }
            }
        }
        // 保留选择及详情行为；翻到第二页再返回后仍采用同一几何，不依赖已经遍历过的行。
        model.selection = [ids[0]]
        try await until { model.detail != nil }
        #expect(model.selectedRow?.id == ids[0])
        model.go(toPage: 1)
        try await until { model.rows.count == 18 && !model.loading }
        host.layoutSubtreeIfNeeded()
        try await until { table.numberOfRows == 18 }
        let secondPageHeight = table.frame.height
        table.scrollRowToVisible(17); host.layoutSubtreeIfNeeded()
        #expect(abs(table.frame.height - secondPageHeight) < 0.5)
        model.go(toPage: 0)
        try await until { model.rows.count == 50 && !model.loading }
        host.layoutSubtreeIfNeeded()
        try await until { table.numberOfRows == 50 }
        #expect(abs(table.frame.height - firstPageHeight) < 0.5)
        #expect(model.selection.isEmpty)
        #expect(!window.isVisible)
        #expect(scroll.hasVerticalScroller)
    }

    /// 无表格祖先时不修改旁边表格；重挂接后只作用于新的宿主。
    @Test func markerIsLocalAndIdempotent() {
        let container = NSView(), unrelated = NSTableView(), target = NSTableView()
        unrelated.usesAutomaticRowHeights = true; unrelated.rowHeight = 30
        container.addSubview(unrelated); container.addSubview(target)
        let marker = HistoryManagerFixedRowHeight.Marker()
        container.addSubview(marker); marker.apply()
        #expect(unrelated.usesAutomaticRowHeights && unrelated.rowHeight == 30)
        target.addSubview(marker); marker.apply(); marker.apply()
        #expect(!target.usesAutomaticRowHeights && target.rowHeight == 56)
        #expect(unrelated.usesAutomaticRowHeights && unrelated.rowHeight == 30)
        #expect(marker.hitTest(.zero) == nil)
    }
}
