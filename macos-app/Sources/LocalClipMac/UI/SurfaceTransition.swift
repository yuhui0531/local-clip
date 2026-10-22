// 后台工具主界面的草稿保护与可中断淡化；与具体窗口布局解耦，by AI.Coding。
import AppKit
import SwiftUI

enum AppSurface: Hashable { case cards, settings, manager }

@MainActor final class SurfaceEdits {
    enum Choice { case save, discard, cancel }
    struct Draft {
        var title: String
        var dirty: () -> Bool
        var save: () async -> Bool
        var discard: () -> Void
    }
    private var drafts: [UUID: (AppSurface, Draft)] = [:]
    private(set) var resolving = false
    /// 由视图登记仍在编辑的值；闭包读取状态绑定，不复制草稿文本。
    func register(_ id: UUID, surface: AppSurface, draft: Draft) { drafts[id] = (surface, draft) }
    /// 视图退出时解除闭包引用，防止已释放的窗口被草稿注册表保留。
    func remove(_ id: UUID) { drafts[id] = nil }
    /// 主界面释放时兜底清除所有草稿持有者。
    func removeAll(_ surface: AppSurface) { drafts = drafts.filter { $0.value.0 != surface } }
    /// 未修改的输入不阻止窗口切换。
    func hasChanges(_ surface: AppSurface) -> Bool { drafts.values.contains { $0.0 == surface && $0.1.dirty() } }
    /// 一次确认只保护原请求，期间的新请求直接拒绝；保存失败保留原界面。
    func resolve(_ surface: AppSurface, choose: (String) async -> Choice) async -> Bool {
        guard !resolving else { return false }
        resolving = true
        defer { resolving = false }
        let pending = drafts.values.filter { $0.0 == surface && $0.1.dirty() }.map(\.1)
        guard !pending.isEmpty else { return true }
        switch await choose(pending.map(\.title).joined(separator: "、")) {
        case .cancel: return false
        case .discard: pending.forEach { $0.discard() }; return true
        case .save:
            for draft in pending { guard await draft.save() else { return false } }
            return true
        }
    }
}

/// 动效插值保持单调，不回弹；减少动态效果仍保留短淡化。
enum SurfaceMotion {
    static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0.10 : 0.20 }
    static func value(from: Double, to: Double, progress: Double) -> Double {
        let t = min(1, max(0, progress)), eased = t * t * (3 - 2 * t)
        return from + (to - from) * eased
    }
}

/// 直接推进实际透明度，取消后从当前值继续，旧任务不会完成新窗口的释放。
@MainActor final class SurfaceAnimator {
    private var task: Task<Void, Never>?
    /// 所有非目标窗口只绘制、不交互；结束操作由宿主按当前代次决定。
    func animate(_ windows: [(NSWindow, Double)], reduceMotion: Bool, completion: @escaping () -> Void) {
        task?.cancel()
        let starts = windows.map { $0.0.alphaValue }
        task = Task {
            let start = ContinuousClock.now, duration = SurfaceMotion.duration(reduceMotion: reduceMotion)
            while !Task.isCancelled {
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = min(1, seconds / duration)
                for (index, pair) in windows.enumerated() {
                    pair.0.alphaValue = SurfaceMotion.value(from: starts[index], to: pair.1, progress: progress)
                }
                if progress >= 1 { completion(); return }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
        }
    }
    /// 应用退出时不再持有窗口或回调。
    func cancel() { task?.cancel(); task = nil }
}
