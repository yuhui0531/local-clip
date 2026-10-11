// 隔离GUI验收仅编译到Debug验收包；正式Release无数据目录/剪贴板/性能驱动入口，by AI.Coding。
#if DEBUG
import AppKit
import SwiftUI
import QuartzCore
import Darwin
import LocalClipCore

@MainActor enum GUIAcceptanceProbe {
    static let launched = ContinuousClock.now
    static let configuration: [String: String]? = {
        guard let file = Bundle.main.resourceURL?.appendingPathComponent("IsolatedGUIProbe.json"),
              let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode([String: String].self, from: data),
              value["root"] != nil, value["output"] != nil, value["board"]?.hasPrefix("local.localclip.gui.") == true else { return nil }
        return value
    }()
    static var output: URL? { configuration?["output"].map { URL(fileURLWithPath: $0) } }
    private static var pending: (String, ContinuousClock.Instant, String?, String?, UUID)?
    static var imageReadyIDs = Set<ClipID>()
    private static var expectedGeneration: UUID?
    private static var excludedID: ClipID?
    private static var samples: [String: [Double]] = [:]
    private static var completed = Set<UUID>()
    private static var trace: [[String: Any]] = []
    private static var pointers: [[String: Any]] = []
    static func pointer(_ event: NSEvent, id: String?, rectangles: [[String: String]]) {
        pointers.append(["type":event.type.rawValue,"point":NSStringFromPoint(event.locationInWindow),"buttons":NSEvent.pressedMouseButtons,"id":id ?? "","rectangles":rectangles])
        write(pointers, "native-pointer.json")
    }
    static var show: (() -> Void)?
    static var hide: (() -> Void)?
    private static var task: Task<Void, Never>?
    static func write(_ object: Any, _ file: String) {
        guard let output else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent(file), options: .atomic)
    }
    static func inputChanged(_ query: String) { if configuration != nil { _ = start("actualInputToDraw", query: query) } }
    static func imageBecameReady(_ id: ClipID) {
        imageReadyIDs.insert(id)
    }
    static func event(_ name: String, _ model: HistoryViewModel) {
        guard output != nil else { return }
        trace.append(["event":name,"uptime":ProcessInfo.processInfo.systemUptime,"selectedID":model.selectedID ?? "", "selectedIDs":model.selectedIDs.sorted(),"draggedIDs":model.draggedIDs.sorted(),"dragActive":model.dragActive])
        write(trace, "events.json")
    }
    static func start(_ name: String, query: String? = nil, clip: String? = nil, at: ContinuousClock.Instant = .now) -> UUID {
        let token = UUID(); expectedGeneration = nil; pending = (name, at, query, clip, token); return token
    }
    static func drawn(query: String, generation: UUID, first: String?, firstID: String?, firstImage: Bool, loading: Bool, window: NSWindow?) {
        guard let value = pending, !loading, window?.isVisible == true,
              expectedGeneration == nil || expectedGeneration == generation,
              !firstImage || firstID.map({ imageReadyIDs.contains($0) }) == true,
              value.2 == nil || value.2 == query, value.3 == nil || value.3 == first,
              excludedID == nil || (firstID != excludedID && firstID.map({ imageReadyIDs.contains($0) }) == true) else { return }
        let d = value.1.duration(to: .now)
        samples[value.0, default: []].append(Double(d.components.seconds)*1000+Double(d.components.attoseconds)/1e15)
        completed.insert(value.4); pending = nil; excludedID = nil
        write(["boundary":"production model/service pipeline to AppKit display completion in visible NSHostingView; excludes physical keystroke transport and GPU scanout", "optimization":"-O, DEBUG acceptance instrumentation", "samplesMs":samples], "gui-samples.json")
    }
    private static func wait(_ token: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !completed.contains(token), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        guard completed.remove(token) != nil else { throw StoreError.ioFailure }
    }
    static func attach(model: HistoryViewModel, board: NativePasteboardAccess, show: @escaping () -> Void, hide: @escaping () -> Void) {
        guard configuration != nil else { return }
        self.show = show; self.hide = hide
        // 验收包独立激活，避免自动化工具在非激活面板刚出现时把它立即切走。
        NSApp.activate(ignoringOtherApps: true)
        _ = start("coldLaunch", at: launched); show()
        // 只记录隔离合成fixture状态，不读取用户数据库和general正文。
        task = Task {
            while !Task.isCancelled {
                let window = NSApp.windows.first { $0.title == "LocalClip" }
                write(["visible":window?.isVisible ?? false,"key":window?.isKeyWindow ?? false,"loading":model.loading,"query":model.query,"selectedID":model.selectedID ?? "", "selectedIDs":model.selectedIDs.sorted(), "draggedIDs":model.draggedIDs.sorted(),"dragActive":model.dragActive,"items":model.items.prefix(50).map { ["id":$0.id,"preview":$0.preview] },"frame":NSStringFromRect(window?.frame ?? .zero),"message":model.message], "state.json")
                if let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-show").path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-show"))
                    NSApp.activate(ignoringOtherApps: true); show()
                }
                if let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-idle").path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-idle"))
                    do { try await idle(model: model) } catch { write(["failure":String(describing:error)], "idle-failure.json") }
                }
                // 文件命令只在明确标记的隔离验收包存在，正式Release没有此入口。
                if let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-benchmark").path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-benchmark"))
                    do { try await benchmark(model: model, board: board) }
                    catch { write(["failure":String(describing:error)], "gui-failure.json") }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private static func idle(model: HistoryViewModel) async throws {
        hide?()
        var settings = try await model.store.settings(); settings.captureEnabled = true
        model.guiApplySettings(try await model.store.updateCaptureSettings(settings))
        try await Task.sleep(for: .seconds(10))
        func resources() -> (Double, Int64) {
            var value = rusage(); getrusage(RUSAGE_SELF, &value)
            let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec)/1e6
            var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return (cpu, result == KERN_SUCCESS ? Int64(info.resident_size) : -1)
        }
        var previous = resources(), instant = ContinuousClock.now, values: [[String: Any]] = []
        for index in 0..<120 {
            try await Task.sleep(for: .seconds(5))
            let current = resources(), duration = instant.duration(to: .now)
            let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds)/1e18
            values.append(["index":index,"elapsedSeconds":elapsed,"cpuPercent":(current.0-previous.0)/elapsed*100,"residentBytes":current.1])
            previous = current; instant = .now
            write(["scope":"optimized isolated AppDelegate GUI process, panel hidden, production capture active on unchanged named board; instrumentation writes once per 5 s", "warmupSeconds":10,"samples":values,"energy":"unavailable","wakeups":"unavailable"], "gui-idle.json")
        }
        settings = try await model.store.settings(); settings.captureEnabled = false
        model.guiApplySettings(try await model.store.updateCaptureSettings(settings))
        write(["complete":true,"n":values.count], "idle-complete.json")
    }
    private static func benchmark(model: HistoryViewModel, board: NativePasteboardAccess) async throws {
        var settings = try await model.store.settings(); settings.captureEnabled = true
        model.guiApplySettings(try await model.store.updateCaptureSettings(settings))
        model.query = ""; model.searchChanged(); show?(); try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<200 {
            hide?(); try await Task.sleep(for: .milliseconds(20))
            let token = start("warmOpen"); show?(); try await wait(token)
        }
        let queries = ["需求", "代", "foo_bar", "50%", "a->b", "?a=1&b=2", "END-9999", "fixture-1234", "missing-literal", "The local"]
        for index in 0..<200 {
            if index % 2 == 0 {
                model.query = ""; model.searchChanged()
                try await Task.sleep(for:.milliseconds(200))
                let revision = try await model.store.settings().revision
                guard case .inserted = try await model.store.ingest(.init(payload:.init([.init([.init(SupportedType.string, Data("gui-search-cold-\(index)".utf8))])]),revision:revision),at:SystemClock().now()) else { throw StoreError.ioFailure }
                let deadline = ContinuousClock.now + .seconds(8)
                while model.items.first?.preview != "gui-search-cold-\(index)" || model.loading {
                    guard ContinuousClock.now < deadline else { throw StoreError.ioFailure }
                    try await Task.sleep(for:.milliseconds(2))
                }
            }
            let query = queries[index % queries.count]
            let token = start(index % 2 == 0 ? "coldSearch" : "warmSearch", query: query)
            model.query = query; model.searchChanged(); expectedGeneration = model.guiQueryGeneration; try await wait(token)
        }
        model.query = ""; model.searchChanged(); try await Task.sleep(for:.milliseconds(200))
        settings = try await model.store.settings(); settings.captureEnabled = true
        model.guiApplySettings(try await model.store.updateCaptureSettings(settings))
        for index in 0..<200 {
            let text = "gui-capture-\(index)-" + UUID().uuidString
            let token = start("textCopyToDraw", clip: text)
            board.board.clearContents()
            guard board.board.setString(text, forType: .string) else { throw StoreError.ioFailure }
            try await wait(token)
        }
        // 已生成真实PNG编码fixture，计时只包括系统写入/轮询/入库/刷新/绘制，不包括编码。
        guard let output else { throw StoreError.ioFailure }
        for index in 0..<20 {
            let data = try Data(contentsOf: output.appendingPathComponent("image-\(index).png"))
            let hash = ContentFingerprint.hash(data)
            excludedID = model.items.first?.id
            let token = start("imageCopyToDraw")
            board.board.clearContents()
            guard board.board.setData(data, forType: .png) else { throw StoreError.ioFailure }
            try await wait(token)
            event("image-drawn-\(hash)", model)
        }
        settings = try await model.store.settings(); settings.captureEnabled = false
        model.guiApplySettings(try await model.store.updateCaptureSettings(settings))
        write(["complete":true,"counts":samples.mapValues(\.count)], "gui-complete.json")
    }
}
struct GUIRenderWitness: NSViewRepresentable {
    let displayCycle: UUID
    let query: String
    let generation: UUID
    let first: String?
    let firstID: String?
    let firstImage: Bool
    let ready: Bool
    let loading: Bool
    func makeNSView(context: Context) -> Witness { Witness() }
    func updateNSView(_ view: Witness, context: Context) {
        let marker = Witness.Marker(displayCycle: displayCycle, query: query, generation: generation, first: first, firstID: firstID, firstImage: firstImage, ready: ready, loading: loading)
        guard view.marker != marker else { return }
        view.marker = marker
        view.needsDisplay = true
    }
    final class Witness: NSView {
        struct Marker: Equatable {
            let displayCycle: UUID
            let query: String, generation: UUID, first: String?, firstID: String?, firstImage: Bool, ready: Bool, loading: Bool
        }
        var marker: Marker?
        private var reported: Marker?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let marker, marker != reported, let window, window.isVisible else { return }
            reported = marker
            // 观察自然绘制后的事务完成，不从draw中递归布局或强迫第二次全窗口重绘，by AI.Coding。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.marker == marker, marker.ready, window.isVisible else { return }
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    MainActor.assumeIsolated {
                        guard self.marker == marker, window.isVisible else { return }
                        GUIAcceptanceProbe.drawn(query: marker.query, generation: marker.generation, first: marker.first, firstID: marker.firstID, firstImage: marker.firstImage, loading: marker.loading, window: window)
                    }
                }
                CATransaction.commit(); CATransaction.flush()
            }
        }
    }
}
#endif
