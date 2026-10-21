// 列表与输入各自发布，不把卡片更新转发给工具栏和分类行，by AI.Coding。
import SwiftUI
import LocalClipCore

@MainActor final class HistoryQueryState: ObservableObject {
    @Published var literal = ""
}

@MainActor final class HistoryFooterState: ObservableObject {
    /// 文字输出能力只随所选内容变化；元数据回填和分页不应让按钮反复置灰。
    struct TextCapabilityKey: Equatable {
        var ids: Set<ClipID> = []
        var fingerprints: [ClipID: String] = [:]
    }
    struct Snapshot: Equatable {
        var itemCount = 0
        var selectedCount = 0
        var selectedIDs: Set<ClipID> = []
        var selectedID: ClipID?
        var selectedItem: ClipSummary?
        var selectedMetadata: ClipMetadata?
        var loading = false
        var hasMore = false
        var textCapability = TextCapabilityKey()
    }
    @Published private(set) var snapshot = Snapshot()
    fileprivate func update(from list: HistoryListState.Snapshot, metadata: ClipMetadata?) {
        let value = Snapshot(itemCount: list.items.count, selectedCount: list.selectedIDs.count, selectedIDs: list.selectedIDs,
            selectedID: list.selectedID, selectedItem: list.items.first { $0.id == list.selectedID },
            selectedMetadata: metadata, loading: list.loading, hasMore: list.cursor != nil,
            textCapability: .init(ids: list.selectedIDs, fingerprints: Dictionary(uniqueKeysWithValues:
                list.items.filter { list.selectedIDs.contains($0.id) }.map { ($0.id, $0.contentFingerprint ?? "") })))
        if value != snapshot { snapshot = value }
    }
}

/// 只给空状态订阅：换范围查询未返回时不显示旧提示，失败时不冒充空历史，by AI.Coding。
@MainActor final class HistoryQueryStatus: ObservableObject {
    @Published private(set) var switching = false
    @Published private(set) var failed = false
    func update(switching: Bool? = nil, failed: Bool? = nil) {
        if let switching, switching != self.switching { self.switching = switching }
        if let failed, failed != self.failed { self.failed = failed }
    }
}

@MainActor final class HistoryListState: ObservableObject {
    struct Snapshot: Equatable {
        var items: [ClipSummary] = []
        var selectedIDs: Set<ClipID> = []
        var selectedID: ClipID?
        var loading = false
        var cursor: SearchCursor?
        var scrollRestoration: HistoryViewModel.ScrollRestoration?
        /// 新查询替换整个列表时递增；滚动区据此重建身份。
        var scrollEpoch = 0
        /// 只为一次成功拖放的列表发布启用短位移动画，by AI.Coding。
        var reorderRevision = 0
    }
    @Published private(set) var snapshot = Snapshot()
    let footerState = HistoryFooterState()
    let queryStatus = HistoryQueryStatus()
    private var pending: Snapshot?
    /// 选择元数据只有底栏消费，不让异步元数据结果重新计算整条历史，by AI.Coding。
    var selectedMetadata: ClipMetadata? {
        didSet {
            if pending == nil, selectedMetadata != oldValue {
                footerState.update(from: snapshot, metadata: selectedMetadata)
            }
        }
    }
    /// 同步修改累积在一个快照里，观察者只收到完成后的列表、游标与选择，by AI.Coding。
    func update(_ body: () -> Void) {
        if pending != nil { body(); return }
        pending = snapshot; body()
        let value = pending!; pending = nil
        if value != snapshot { snapshot = value }
        footerState.update(from: value, metadata: selectedMetadata)
    }
    subscript<Value: Equatable>(_ key: WritableKeyPath<Snapshot, Value>) -> Value {
        get { (pending ?? snapshot)[keyPath: key] }
        set {
            if pending != nil { pending![keyPath: key] = newValue }
            else if snapshot[keyPath: key] != newValue {
                var value = snapshot; value[keyPath: key] = newValue
                snapshot = value; footerState.update(from: value, metadata: selectedMetadata)
            }
        }
    }
}
