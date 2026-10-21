// 历史管理窗口按页码取页：起始位置、总数与排序在浏览和字面检索两条路径一致，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct HistoryPagingTests {
    private func makeStore(_ count: Int) async throws -> (HistoryStore, TestClock, [ClipID], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = TestClock(); let store = try HistoryStore(location: root, clock: clock)
        var ids: [ClipID] = []
        for index in 0..<count { ids.append(insertedID(try await store.ingest(fixture("page-\(index)"), at: clock.now()))); clock.advance(1) }
        return (store, clock, ids, root)
    }
    @Test func offsetPageAndTotalMatchForBrowseAndLiteral() async throws {
        let (store, _, ids, root) = try await makeStore(60)
        defer { try? FileManager.default.removeItem(at: root) }
        let newest = Array(ids.reversed())
        for literal in ["", "page-"] {
            var request = SearchRequest(literal, pageSize: 25); request.offset = 25; request.countTotal = true
            let page = try await store.search(request)
            #expect(page.items.map(\.id) == Array(newest[25..<50]))
            #expect(page.total == 60)
            // 末页不足一页；越过末尾的字面检索返回空页而不是旧数据。
            request.offset = 50
            let last = try await store.search(request)
            #expect(last.items.map(\.id) == Array(newest[50...]) && last.next == nil && last.total == 60)
            // 面板默认不统计；游标续页不重复统计。
            let plain = try await store.search(.init(literal, pageSize: 25))
            #expect(plain.total == nil)
            #expect(try await store.search(.init(literal, cursor: plain.next, pageSize: 25)).total == nil)
        }
        var filtered = SearchRequest("page-5", pageSize: 25); filtered.countTotal = true
        #expect(try await store.search(filtered).total == 11)
    }
    /// 1万条下按页码取首页、末页（含总数）与一页分类归属的耗时；结果打印到测试输出，by AI.Coding。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_MANAGER_PERF"] == "1"))
    func tenThousandRowPaging() async throws {
        let (store, _, _, root) = try await makeStore(10_000)
        defer { try? FileManager.default.removeItem(at: root) }
        for literal in ["", "page-"] {
            for offset in [0, 9_950] {
                var request = SearchRequest(literal, pageSize: 50); request.offset = offset; request.countTotal = true
                var samples: [Double] = []
                for _ in 0..<5 {
                    let started = ContinuousClock.now
                    let page = try await store.search(request)
                    let elapsed = (ContinuousClock.now - started).components
                    samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                    if offset == 0 { _ = try await store.categoryMemberships(page.items.map(\.id)) }
                }
                print("manager-perf literal=\"\(literal)\" offset=\(offset) median_ms=\(samples.sorted()[2])")
            }
        }
    }
    @Test func firstOffsetLocatesBrowseRows() async throws {
        let (store, _, ids, root) = try await makeStore(60)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await store.firstOffset(of: [ids[0]], in: .init()) == 59)
        #expect(try await store.firstOffset(of: [ids[0], ids[30]], in: .init()) == 29)
        #expect(try await store.firstOffset(of: ["missing"], in: .init()) == nil)
        #expect(try await store.firstOffset(of: [ids[0]], in: .init("page-")) == nil)
    }
    /// 目标已不存在的删除不能清除上一次删除的撤销。
    @Test func emptyDeleteKeepsUndo() async throws {
        let (store, _, ids, root) = try await makeStore(2)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store.apply(try await store.preview(.delete([ids[0]])).token)
        _ = try await store.apply(try await store.preview(.delete([ids[0]])).token)
        #expect(await store.undoAvailable())
        try await store.undoDelete()
        #expect(try await store.search(.init()).items.count == 2)
    }
    /// 续页身份：插入使游标失效；图片文字索引不推进revision，但派生代次变化可被识别。
    @Test func cursorAndDerivedGenerationDetectChanges() async throws {
        let (store, clock, _, root) = try await makeStore(60)
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await store.search(.init("page-"))
        _ = try await store.ingest(fixture("page-new"), at: clock.now())
        await #expect(throws: StoreError.self) { try await store.search(.init("page-", cursor: head.next)) }
        let png = Data(repeating: 7, count: 64)
        let picture = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, png)])])), at: clock.now()))
        // 采集快照绑定策略版本，开启图片文字搜索放在采集之后。
        var settings = try await store.settings(); settings.imageTextSearchSince = 1
        _ = try await store.updateCaptureSettings(settings)
        let before = try await store.search(.init("page-"))
        #expect(try await store.saveImageText(.init(clipID: picture, itemIndex: 0), digest: ContentFingerprint.hash(png), text: "page-ocr"))
        let after = try await store.search(.init("page-", cursor: before.next))
        #expect(after.revision == before.revision && after.derivedGeneration != before.derivedGeneration)
    }
    @Test func sortOrdersApplyToBothPaths() async throws {
        let (store, clock, ids, root) = try await makeStore(5)
        defer { try? FileManager.default.removeItem(at: root) }
        // 再次复制最早的一条：最近复制与次数都排到最前，首次复制时间不变。
        _ = try await store.ingest(fixture("page-0"), at: clock.now())
        for literal in ["", "page-"] {
            func order(_ sort: HistorySortOrder) async throws -> [ClipID] { try await store.search(.init(literal, sort: sort)).items.map(\.id) }
            #expect(try await order(.recentDesc) == [ids[0], ids[4], ids[3], ids[2], ids[1]])
            #expect(try await order(.recentAsc) == [ids[1], ids[2], ids[3], ids[4], ids[0]])
            #expect(try await order(.copyCountDesc).first == ids[0])
            #expect(try await order(.firstCopiedDesc) == [ids[4], ids[3], ids[2], ids[1], ids[0]])
        }
    }
}
