// LC-R03/R04：真实原生托管与OCR验证筛选可见性和隐私提示，by AI.Coding。
import AppKit
import SwiftUI
import Vision
import Testing
import LocalClipCore
@testable import LocalClipMac

// 桌面展示另需明确授权；原有专项开关仍保留，by AI.Coding。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_INTERACTIVE_TESTS"] == "1", "Requires explicit user request for desktop interaction"))
@MainActor struct ReviewRemediationVisualTests {
    /// 0/3分类全部可见；10分类可以滚动到最后一项，底部操作栏保持可见。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REMEDIATION_VISUAL"] == "1"), arguments: [0, 3, 10])
    func filterAndPrivacyLayouts(count: Int) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.excludedBundleIDs = ["local.test.excluded"]
        let store = try HistoryStore(location: root, initialSettings: settings)
        for index in 0..<count { _ = try await store.createCategory(name: String(format: "ReviewCategory%02d", index + 1), colorHex: "34C759") }
        let board = MacPasteboardClient(access: RawBoard()), capture = CaptureCoordinator(board: board, store: store)
        let model = HistoryViewModel(store: store, capture: capture, paste: PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture), derived: DerivedContentService(store: store))
        try await model.start(); capture.stop()
        let until = ContinuousClock.now + .seconds(15)
        while model.categories.count != count, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        // 与真实popover一致的浅色不透明背景，避免透明像素干扰OCR。
        let host = NSHostingView(rootView: AnyView(FilterEditor(model: model).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)))
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        func snapshot(_ name: String) throws -> String {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["LOCALCLIP_REMEDIATION_VISUAL_OUTPUT"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            }
            let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        let initial = try snapshot("filter-\(count)")
        #expect(initial.contains("完成"), "\(initial)")
        if count == 3 { #expect(initial.lowercased().contains("reviewcategory03"), "\(initial)") }
        if count == 10 {
            func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
            let scroll = try #require(scrollViews(host).first(where: { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height }))
            let document = try #require(scroll.documentView)
            scroll.contentView.scroll(to: .init(x: 0, y: document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(300))
            let final = try snapshot("filter-10-scrolled")
            #expect(final.lowercased().contains("reviewcategory10"), "\(final)")
            #expect(final.contains("完成"), "\(final)")
        }
        if count == 0 {
            host.rootView = AnyView(SettingsView(model: model, login: LoginItemService(), section: .privacy, fitWindow: { _ in }).environment(\.colorScheme, .light))
            window.setContentSize(.init(width: 640, height: 640))
            try await Task.sleep(for: .milliseconds(300))
            let privacy = try snapshot("privacy-warning")
            #expect(privacy.contains("多数应用"), "\(privacy)")
            #expect(privacy.contains("开启前台"), "\(privacy)")
            #expect(try await store.settings().pauseWhenExcludedFrontmost == false)
        }
    }
}
