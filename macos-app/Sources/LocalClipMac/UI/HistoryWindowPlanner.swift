import LocalClipCore

struct HistoryWindowPlan {
    let items: [ClipSummary]
    let cursor: SearchCursor?
}

/// 保留窗口和选择锚点并计算无跳行续页位置，by AI.Coding。
func planHistoryWindow(pages: [SearchPage], windowSize: Int, anchors: Set<ClipID>) -> HistoryWindowPlan {
    let values = pages.flatMap(\.items)
    guard let lastPage = pages.last else { return .init(items: [], cursor: nil) }
    let anchorEnd = values.lastIndex { anchors.contains($0.id) }.map { $0 + 1 } ?? 0
    let retainedCount = min(values.count, max(windowSize, anchorEnd))
    var cursor = lastPage.next
    if retainedCount < values.count {
        cursor = pages.dropLast().last?.next ?? lastPage.next
        cursor?.offset = retainedCount
    }
    return .init(items: Array(values.prefix(retainedCount)), cursor: cursor)
}
