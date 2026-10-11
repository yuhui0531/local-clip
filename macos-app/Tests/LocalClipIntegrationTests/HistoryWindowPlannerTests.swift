import Foundation
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

struct HistoryWindowPlannerTests {
    private func summary(_ index: Int) -> ClipSummary {
        .init(id: "window-\(index)", firstCopiedAt: Int64(index), lastCopiedAt: Int64(index), copyCount: 1,
              kind: .text, isFavorite: false, source: .unknown, preview: "\(index)", context: "")
    }
    private func page(_ range: Range<Int>, nextOffset: Int?) -> SearchPage {
        .init(queryID: UUID(), revision: 4, items: range.map(summary),
              next: nextOffset.map { .init(revision: 4, offset: $0, signature: "query") })
    }

    /// 窗口截断、远端选择锚点及空结果都保持排序与精确续页位置，by AI.Coding。
    @Test func plansRetainedWindowAndCursor() {
        let secondCursor = SearchCursor(revision: 4, offset: 10, signature: "query")
        let cases: [(String, [SearchPage], Int, Set<ClipID>, [String], SearchCursor?)] = [
            ("empty", [], 5, [], [], nil),
            ("truncate initial page", [page(0..<5, nextOffset: 5)], 3, [], ["window-0", "window-1", "window-2"], .init(revision: 4, offset: 3, signature: "query")),
            ("retain selection anchor", [page(0..<5, nextOffset: 5), page(5..<10, nextOffset: 10)], 6, ["window-8"], (0..<9).map { "window-\($0)" }, .init(revision: 4, offset: 9, signature: "query")),
            ("preserve last page cursor", [page(0..<5, nextOffset: 5), page(5..<10, nextOffset: 10)], 10, [], (0..<10).map { "window-\($0)" }, secondCursor),
            ("truncate before terminal page", [page(0..<5, nextOffset: 5), page(5..<7, nextOffset: nil)], 4, [], (0..<4).map { "window-\($0)" }, .init(revision: 4, offset: 4, signature: "query")),
            ("missing anchor does not extend window", [page(0..<5, nextOffset: 5), page(5..<10, nextOffset: 10)], 6, ["missing"], (0..<6).map { "window-\($0)" }, .init(revision: 4, offset: 6, signature: "query"))
        ]
        for (name, pages, size, anchors, expectedIDs, expectedCursor) in cases {
            let result = planHistoryWindow(pages: pages, windowSize: size, anchors: anchors)
            #expect(!name.isEmpty)
            #expect(result.items.map(\.id) == expectedIDs)
            #expect(result.cursor == expectedCursor)
        }
    }
}
