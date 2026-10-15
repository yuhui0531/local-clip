// 相同 Release 宿主真实托管 HistoryView，比较浏览/隐藏/重开；仅合成数据和假剪贴板，by AI.Coding。
import AppKit
import SwiftUI
import Darwin
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；原有专项开关仍保留，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct ThumbnailMemoryBenchmark {
    /// 测试进程的实际物理占用，不把缓存计数当作进程内存。
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    /// 单调时间毫秒。
    private func ms(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    /// 有界等待生产异步加载，失败时禁止产生成功基准。
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }
    /// 40张真实PNG逐项浏览；20次快速重开及31秒隐藏后的20次重开，保存原始样本。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_MEMORY_BENCHMARK"] == "1"))
    func browseHideReopen() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCLIP_MEMORY_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("store")
        let store = try HistoryStore(location: root), now = SystemClock().now()
        for index in 0..<40 {
            let data = try autoreleasepool { try ImageFixtures.image(width: 800 + index, height: 800) }
            _ = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, data)])])), at: now + Int64(index))
        }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        model.configureHistoryViewport(width: 1000, cardWidth: 230)
        try await model.start(); capture.stop()
        try await wait { !model.historyBusy && !model.items.isEmpty }
        model.edgeSelection(true, extend: false)
        try await wait { !model.historyBusy && model.items.count == 40 }
        model.select(model.items.first?.id)
        let host = NSHostingView(rootView: HistoryView(model: model)); host.sizingOptions = []
        let window = NSPanel(contentRect: .init(x: 0, y: 0, width: 1000, height: 340), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { capture.stop(); window.contentView = nil; window.close() }
        let initial = ContinuousClock.now
        model.panelVisibilityChanged(true); window.orderFront(nil)
        try await wait { model.thumbnails.object(forKey: model.items[0].id as NSString) != nil }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let firstDraw = ms(initial)
        var memory: [String: UInt64] = ["firstVisible": footprint()]
        var cachedCounts: [String: Int] = [:]
        // 按实际选中路径驱动滚动和卡片解码，禁止预先塞满缓存冒充UI浏览。
        for item in model.items {
            model.select(item.id)
            try await wait { model.thumbnails.object(forKey: item.id as NSString) != nil }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .seconds(1))
        memory["afterBrowse"] = footprint()
        cachedCounts["afterBrowse"] = model.items.filter { model.thumbnails.object(forKey: $0.id as NSString) != nil }.count
        var warm: [Double] = [], afterTrim: [Double] = []
        for phase in 0..<2 {
            for _ in 0..<20 {
                model.panelVisibilityChanged(false); window.orderOut(nil)
                try await Task.sleep(for: .milliseconds(30))
                let start = ContinuousClock.now
                model.panelVisibilityChanged(true); window.orderFront(nil)
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let elapsed = ms(start)
                if phase == 0 { warm.append(elapsed) } else { afterTrim.append(elapsed) }
            }
            if phase == 0 {
                model.panelVisibilityChanged(false); window.orderOut(nil)
                try await Task.sleep(for: .seconds(31))
                memory["hidden31s"] = footprint()
                cachedCounts["hidden31s"] = model.items.filter { model.thumbnails.object(forKey: $0.id as NSString) != nil }.count
                // 当前屏的最后一张图必须仍然热命中，避免以占位首帧伪装重开速度。
                #expect(model.thumbnails.object(forKey: model.items.last!.id as NSString) != nil)
            }
        }
        memory["reopened"] = footprint()
        let selected = model.selectedID
        #expect(selected == model.items.last?.id)
        #expect(try await store.search(.init(pageSize: 50)).items.count == 40)
        // 渲染测试窗口本身，既验证重开后真实图片仍在，也留下可复核的像素证据。
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("reopened.png"))
        let result: [String: Any] = ["boundary": "Release Swift Testing process with real NSPanel/HistoryView, synthetic 40 PNGs; excludes installed app, physical key transport and GPU scanout",
            "physicalFootprintBytes": memory, "cachedImageCounts": cachedCounts, "initialVisibleMs": firstDraw, "warmReopenMs": warm, "afterHiddenReopenMs": afterTrim]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("measurements.json"))
        print("MEMORY_BENCHMARK \(output.path)")
    }
}
