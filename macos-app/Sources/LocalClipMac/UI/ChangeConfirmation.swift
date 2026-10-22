// 小型原生附页承载清晰的变更确认，不使用占满弹框的缺省应用图标，by AI.Coding。
import AppKit
import SwiftUI
import LocalClipCore

@MainActor struct ChangeConfirmationCopy {
    var title: String
    var body: String
    var action: String
    var impact: String
    var destructive: Bool
    /// 面板气泡按操作对象定位；每次确认独立标识，避免旧气泡回答新确认，by AI.Coding。
    let operation: HistoryChange
    let id = UUID()

    /// 文案按操作表达后果；零删除明确显示，不把文件计量细节放进用户确认，by AI.Coding。
    init(_ preview: ChangePreview) {
        destructive = preview.affectedCount > 0; operation = preview.operation
        impact = destructive ? "将删除 \(preview.affectedCount) 条记录" : "当前不会删除任何记录"
        switch preview.operation {
        case .retention(let days):
            title = "更改保留期限？"; action = "更改期限"
            body = days == 0 ? "普通历史不再按保留期限自动删除。存储容量限制仍然生效，收藏和分类中的记录会继续保留。" : "普通历史将保留 \(days) 天。超过期限的记录会被删除，收藏和分类中的记录会继续保留。"
        case .quota(let bytes):
            title = "调整存储容量？"; action = "调整容量"
            body = "容量将调整为 \(HistoryViewModel.bytes(bytes))。需要释放空间时，从最早复制的普通历史开始清理；收藏和分类中的记录会继续保留。"
        case .clearOrdinary:
            title = "清空普通历史？"; action = "清空历史"
            body = "收藏和分类中的记录会继续保留。清空操作无法撤销。"
        case .deleteCategory:
            title = "删除这个分类？"; action = "删除分类"
            body = "有效历史记录会保留。已经到期、且失去最后一项保护的记录会被删除。"
        case .favorite, .favorites:
            title = "取消收藏？"; action = "取消收藏"
            body = "已经到期、且不属于任何分类的记录会被删除。"
        case .category:
            title = "移出分类？"; action = "移出分类"
            body = "已经到期、且没有收藏或其他分类保护的记录会被删除。"
        case .delete:
            title = "删除所选记录？"; action = "删除记录"; body = preview.message
        }
    }
}

@MainActor enum ChangeConfirmation {
    /// 只承载设置窗口发起的确认；底栏历史面板贴屏幕底边且覆盖Dock，附页会抬起或撑高面板，改由面板内浮层确认，by AI.Coding。
    /// 异步等待真实用户选择，保留预览版本校验；不阻塞采集任务，不跳过确认策略，by AI.Coding。
    /// parent由调用方显式给出；后台应用的非激活窗口不一定是key窗口，by AI.Coding。
    static func confirm(_ preview: ChangePreview, parent: NSWindow? = NSApp.keyWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            let controller = Controller(preview: preview, continuation: continuation)
            controller.present(parent: parent)
        }
    }

    @MainActor private final class Controller: NSWindowController, NSWindowDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private weak var parent: NSWindow?
        private var parentCloseObserver: NSObjectProtocol?
        init(preview: ChangePreview, continuation: CheckedContinuation<Bool, Never>) {
            let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 440, height: 260), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.title = ""; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false; panel.isMovable = false
            super.init(window: panel)
            self.continuation = continuation; panel.delegate = self
            let copy = ChangeConfirmationCopy(preview)
            // 内容闭包保留控制器直到回答，结束时释放托管内容以断开生命周期环，by AI.Coding。
            let host = NSHostingView(rootView: Content(copy: copy, answer: { self.finish($0) }))
            panel.contentView = host; panel.setContentSize(host.fittingSize)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        func present(parent: NSWindow?) {
            guard let window else { finish(false); return }
            self.parent = parent
            if let parent, parent.attachedSheet == nil {
                parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(false) }
                }
                parent.beginSheet(window) { [weak self] _ in self?.finish(false) }
            } else {
                window.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                window.center(); window.makeKeyAndOrderFront(nil)
            }
        }
        /// 按钮、Escape或父窗口关闭只响应一次，取消不改变持久化数据，by AI.Coding。
        private func finish(_ accepted: Bool) {
            guard let continuation else { return }; self.continuation = nil
            if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver); self.parentCloseObserver = nil }
            if let window {
                if parent?.attachedSheet === window { parent?.endSheet(window) }
                window.orderOut(nil); window.contentView = nil; window.close()
            }
            continuation.resume(returning: accepted)
        }
        func windowWillClose(_ notification: Notification) { finish(false) }
    }

    /// 附页与面板内浮层共用同一确认内容，by AI.Coding。
    struct Content: View {
        let copy: ChangeConfirmationCopy
        let answer: (Bool) -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: "archivebox").font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.blue).frame(width: 44, height: 44)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    Text(copy.title).font(.system(size: 19, weight: .semibold))
                }
                Text(copy.body).font(.system(size: LCStyle.FontSize.body)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(copy.impact, systemImage: copy.destructive ? "trash" : "checkmark.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(copy.destructive ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 10) {
                    Spacer()
                    Button("取消") { answer(false) }.keyboardShortcut(.cancelAction)
                    Button(copy.action) { answer(true) }.keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(copy.destructive ? .red : .accentColor)
                }.controlSize(.large)
            }.padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
                .onExitCommand { answer(false) }
        }
    }
}
