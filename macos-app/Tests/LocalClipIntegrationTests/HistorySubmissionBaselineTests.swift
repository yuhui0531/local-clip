// 仅测隐藏面板的提交边界，真实焦点、窗口置前和出光不在样本内，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac

@MainActor struct HistorySubmissionBaselineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_PANEL_BASELINE"] == "1"), arguments: [true, false])
    func warmPanelSubmission(prepared: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot()
        settings.timingEnabled = true
        let store = try HistoryStore(location: root, initialSettings: settings)
        for index in 0..<3000 {
            let payload = ClipboardPayload([.init([.init(SupportedType.string, Data("panel-fixture-\(index)".utf8))])])
            guard case .inserted = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else {
                Issue.record("合成历史入库失败")
                return
            }
        }
        let board = MacPasteboardClient(access: RawBoard())
        let capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
            paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture),
            derived: DerivedContentService(store: store))
        try await model.start()
        capture.stop()
        model.panelVisibilityChanged(false)
        let app = AppDelegate()
        var samples: [Double] = []
        app.configureSurfacesForTesting(model) { start in
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        for index in 0...50 {
            app.toggleHistoryForTesting()
            for _ in 0..<300 where samples.count <= index { try await Task.sleep(for: .milliseconds(10)) }
            try #require(samples.count == index + 1)
            app.toggleHistoryForTesting()
            for _ in 0..<300 where model.panelVisible { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!model.panelVisible)
            if prepared {
                // 关闭会同步登记首屏准备任务，静默期也计为准备中，by AI.Coding。
                try #require(model.preparingFirstScreen)
                let deadline = ContinuousClock.now + .seconds(5)
                while model.preparingFirstScreen || model.historyBusy {
                    try #require(ContinuousClock.now < deadline)
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        }
        let measured = Array(samples.dropFirst())
        let sorted = measured.sorted()
        let scenario = prepared ? "prepared" : "immediate"
        print("M1 \(scenario) n=\(measured.count) p50=\((sorted[24] + sorted[25]) / 2) p95=\(sorted[47]) max=\(sorted.last!) samples=\(measured)")
    }
}
