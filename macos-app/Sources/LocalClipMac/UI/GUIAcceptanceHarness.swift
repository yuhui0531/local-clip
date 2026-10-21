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
    /// 仅显式构建的外部应用验收包使用系统板；数据库仍隔离，禁用自动写板驱动。
    static var usesExternalPasteboard: Bool { configuration?["externalPasteboard"] == "true" }
    private static var pending: (String, ContinuousClock.Instant, String?, String?, UUID)?
    static var imageReadyIDs = Set<ClipID>()
    private static var expectedGeneration: UUID?
    private static var excludedID: ClipID?
    private static var samples: [String: [Double]] = [:]
    private static var completed = Set<UUID>()
    private static var trace: [[String: Any]] = []
    private static var pointers: [[String: Any]] = []
    private static var exports: [[String: Any]] = []
    /// LC-R01只记录隔离验收包的类型协商和输出结果，不记录载荷正文，by AI.Coding。
    static func exportRequest(_ kind: String, id: String, type: String, provided: Bool, bytes: Int, at: Double, durationMs: Double? = nil, mainThread: Bool? = nil, lockWaitMs: Double? = nil) {
        guard output != nil else { return }
        var entry: [String: Any] = ["kind": kind, "id": id, "type": type, "provided": provided, "bytes": bytes, "uptime": at]
        entry["durationMs"] = durationMs; entry["mainThread"] = mainThread; entry["lockWaitMs"] = lockWaitMs
        exports.append(entry)
        write(exports, "drag-export-requests.json")
    }
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
    /// 主线程卡顿采样：后台每 8ms 投递一次，主线程回应间隔超过 30ms 记一条（系统运行时间），供动画录屏对照，by AI.Coding。
    nonisolated(unsafe) private static var stalls: [[String: Double]] = []
    private static func monitorMainThread() {
        Thread.detachNewThread {
            while true {
                let sent = ProcessInfo.processInfo.systemUptime
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let gap = ProcessInfo.processInfo.systemUptime - sent
                if gap > 0.03 {
                    DispatchQueue.main.async { stalls.append(["at": sent, "ms": (gap * 1000).rounded()]); write(stalls, "main-stalls.json") }
                }
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
    }
    /// 面板背后铺一块彩色带文字的普通窗口，对比磨砂透明度用；只在隔离验收包里出现，by AI.Coding。
    private static var backdrop: NSWindow?
    static func showBackdrop() {
        guard backdrop == nil, let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 460)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        let words = Array(repeating: "LocalClip 磨砂对比 · The quick brown fox jumps over the lazy dog · 0123456789", count: 14).joined(separator: "\n")
        window.contentView = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue, .teal, .green], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 0) { ForEach(0..<12) { index in Rectangle().fill(index.isMultiple(of: 2) ? Color.black.opacity(0.35) : Color.white.opacity(0.35)).frame(width: 60); Spacer() } }
            Text(words).font(.system(size: 22, weight: .bold)).foregroundStyle(.white).shadow(radius: 1)
        })
        window.orderFrontRegardless(); backdrop = window
    }
    /// 文件命令 run-<名称> 触发的额外动作，只在隔离验收包里用于复核动画，by AI.Coding。
    static var commands: [String: () -> Void] = [:]
    /// 测量动画时停写 state.json，避免探针自身占用主线程干扰计时。
    static var quiet = false
    static func attach(model: HistoryViewModel, board: NativePasteboardAccess, show: @escaping () -> Void, hide: @escaping () -> Void) {
        guard configuration != nil else { return }
        monitorMainThread()
        self.show = show; self.hide = hide
        // 验收包独立激活，避免自动化工具在非激活面板刚出现时把它立即切走。
        NSApp.activate(ignoringOtherApps: true)
        _ = start("coldLaunch", at: launched); show()
        // 只记录隔离合成fixture状态，不读取用户数据库和general正文。
        task = Task {
            while !Task.isCancelled {
                let window = NSApp.windows.first { $0.title == "LocalClip" }
                if !quiet { write(["visible":window?.isVisible ?? false,"key":window?.isKeyWindow ?? false,"loading":model.loading,"query":model.query,"selectedID":model.selectedID ?? "", "selectedIDs":model.selectedIDs.sorted(), "draggedIDs":model.draggedIDs.sorted(),"dragActive":model.dragActive,"items":model.items.prefix(50).map { ["id":$0.id,"preview":$0.preview] },"frame":NSStringFromRect(window?.frame ?? .zero),"message":model.message], "state.json") }
                // 明确的隔离验收命令，仅向私有命名剪贴板写合成文本，by AI.Coding。
                if !usesExternalPasteboard, let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-seed" ).path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-seed"))
                    for index in 1...12 {
                        board.board.clearContents()
                        _ = board.board.setString("UX fixture \(index) · 设计应当清晰、自然、易用。", forType: .string)
                        let deadline = ContinuousClock.now + .seconds(3)
                        while !model.items.contains(where: { $0.preview.hasPrefix("UX fixture \(index) ·") }), ContinuousClock.now < deadline {
                            try? await Task.sleep(for: .milliseconds(30))
                        }
                    }
                    write(["seededCount":model.items.count], "seed-result.json")
                }
                if let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-show").path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-show"))
                    NSApp.activate(ignoringOtherApps: true); show()
                }
                for (name, action) in commands where output.map({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("run-\(name)").path) }) == true {
                    try? FileManager.default.removeItem(at: output!.appendingPathComponent("run-\(name)")); action()
                }
                if let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-idle").path) {
                    try? FileManager.default.removeItem(at: output.appendingPathComponent("run-idle"))
                    do { try await idle(model: model) } catch { write(["failure":String(describing:error)], "idle-failure.json") }
                }
                // 文件命令只在明确标记的隔离验收包存在，正式Release没有此入口。
                if !usesExternalPasteboard, let output, FileManager.default.fileExists(atPath: output.appendingPathComponent("run-benchmark").path) {
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
                while model.items.first?.preview != "gui-search-cold-\(index)" || model.historyBusy {
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
