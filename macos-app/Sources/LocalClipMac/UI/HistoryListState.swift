// 列表与输入各自发布，不把卡片更新转发给工具栏和分类行，by AI.Coding。
import SwiftUI
import LocalClipCore

@MainActor final class HistoryQueryState: ObservableObject {
    @Published var literal = ""
}

@MainActor final class HistoryFooterState: ObservableObject {
    struct Snapshot: Equatable {
        var itemCount = 0
        var selectedCount = 0
        var selectedID: ClipID?
        var selectedItem: ClipSummary?
        var selectedMetadata: ClipMetadata?
        var loading = false
        var hasMore = false
    }
    @Published private(set) var snapshot = Snapshot()
    fileprivate func update(from list: HistoryListState.Snapshot, metadata: ClipMetadata?) {
        let value = Snapshot(itemCount: list.items.count, selectedCount: list.selectedIDs.count,
            selectedID: list.selectedID, selectedItem: list.items.first { $0.id == list.selectedID },
            selectedMetadata: metadata, loading: list.loading, hasMore: list.cursor != nil)
        if value != snapshot { snapshot = value }
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
    }
    @Published private(set) var snapshot = Snapshot()
    let footerState = HistoryFooterState()
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
