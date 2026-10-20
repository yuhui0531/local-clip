// F-07 导出逐项清理、F-08 Finder暂存定向恢复、N-01 图片/文件大小；只用临时目录与合成数据，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

struct CleanupAndSizeTests {
    private static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-size-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func unlock(_ root: URL) {
        if let all = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in all { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent(path).path) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// F-07：一个不可删的过期项不阻断其他过期文件；未过期租约保留；容量按真实剩余计算。
    @Test func exportCleanupIsolatesFailures() async throws {
        let root = try Self.root(); defer { Self.unlock(root) }
        let store = try HistoryStore(location: root.appendingPathComponent("data"))
        let exports = root.appendingPathComponent("data/Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -3600)
        let blocked = exports.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: blocked.appendingPathComponent("held"))
        var expired: [URL] = []
        for index in 0..<4 {
            let file = exports.appendingPathComponent("\(index).png")
            try Data(repeating: 2, count: 8192).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            expired.append(file)
        }
        let leased = exports.appendingPathComponent("leased.png")
        try Data(repeating: 3, count: 1000).write(to: leased)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: blocked.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        await #expect(throws: (any Error).self) { try await store.cleanExports() }
        for file in expired { #expect(!FileManager.default.fileExists(atPath: file.path)) }
        #expect(FileManager.default.fileExists(atPath: leased.path) && FileManager.default.fileExists(atPath: blocked.path))
        let usage = try await store.usage()
        #expect(usage.temporary == (try CommitStrategy.bytes(exports)))
        #expect(usage.temporary >= 4096 + 1000 && usage.temporary < 4096 + 1000 + 4 * 8192)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        try await store.cleanExports()
        #expect(!FileManager.default.fileExists(atPath: blocked.path) && FileManager.default.fileExists(atPath: leased.path))
    }

    /// F-08：只回收已登记、令牌吻合且只含暂存项的目录；源、已发布目标、未登记目录、令牌不符与未挂载项保持不变。
    @Test func finderStagingRecoveryIsTargeted() throws {
        let root = try Self.root(); defer { Self.unlock(root) }
        let fm = FileManager.default
        let journal = root.appendingPathComponent("journal"), destination = root.appendingPathComponent("dest")
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt"); try Data("source".utf8).write(to: source)
        let published = destination.appendingPathComponent("published.txt"); try Data("published".utf8).write(to: published)
        func entry(_ token: String, staging: URL) throws {
            let json = try JSONSerialization.data(withJSONObject: ["staging": staging.path, "token": token, "pid": 999_999])
            try json.write(to: journal.appendingPathComponent(token + ".json"))
        }
        func staging(_ token: String, owner: String?, extra: String? = nil, parent: URL? = nil) throws -> URL {
            let url = (parent ?? destination).appendingPathComponent(".localclip-copy-" + token)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: url.appendingPathComponent("0"))
            if let owner { try Data(owner.utf8).write(to: url.appendingPathComponent(".localclip-owner")) }
            if let extra { try Data("user".utf8).write(to: url.appendingPathComponent(extra)) }
            return url
        }
        let ours = UUID().uuidString, wrong = UUID().uuidString, foreign = UUID().uuidString, unregistered = UUID().uuidString, unmounted = UUID().uuidString, gone = UUID().uuidString
        let oursURL = try staging(ours, owner: ours); try entry(ours, staging: oursURL)
        let wrongURL = try staging(wrong, owner: "other"); try entry(wrong, staging: wrongURL)
        let foreignURL = try staging(foreign, owner: foreign, extra: "notes.txt"); try entry(foreign, staging: foreignURL)
        let unregisteredURL = try staging(unregistered, owner: unregistered)
        try entry(unmounted, staging: URL(fileURLWithPath: "/Volumes/LocalClip-Missing-\(UUID().uuidString)/.localclip-copy-" + unmounted))
        try entry(gone, staging: destination.appendingPathComponent(".localclip-copy-" + gone))
        #expect(CopyStagingJournal.recover(journal) == 1)
        #expect(!fm.fileExists(atPath: oursURL.path))
        for url in [wrongURL, foreignURL, unregisteredURL, source, published] { #expect(fm.fileExists(atPath: url.path)) }
        #expect(!fm.fileExists(atPath: "/Volumes/LocalClip-Missing"))
        let remaining = Set(try fm.contentsOfDirectory(atPath: journal.path))
        #expect(remaining == [unmounted + ".json"], "未挂载项保留登记；已处理/不可证明项注销")
        // 正常复制：登记在收尾后注销，暂存不残留，发布语义不变。
        let report = FileObjectCopier.copy([source], to: destination, journal: journal)
        #expect(report.failure == nil && report.copied == 1)
        #expect(try String(contentsOf: destination.appendingPathComponent("source.txt"), encoding: .utf8) == "source")
        #expect(Set(try fm.contentsOfDirectory(atPath: journal.path)) == [unmounted + ".json"])
        #expect(try fm.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".localclip-copy-") }.count == 3)
        // 同名冲突仍停止且不覆盖。
        #expect(FileObjectCopier.copy([source], to: destination, journal: journal).failure != nil)
    }

    /// N-01：图片按主表示（PNG 优先）的已保存字节数，多项合计；只读计数列不加载正文；文本记录无大小。
    @Test func storedImageSizeUsesPrimaryRepresentation() async throws {
        let root = try Self.root(); defer { Self.unlock(root) }
        let store = try HistoryStore(location: root)
        let png = try ImageFixtures.image(width: 40, height: 30, type: SupportedType.png)
        let tiff = try ImageFixtures.image(width: 40, height: 30, type: SupportedType.tiff)
        let jpeg = try ImageFixtures.image(width: 20, height: 20, type: SupportedType.jpeg)
        let now = SystemClock().now()
        guard case .inserted(let single) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.tiff, tiff), .init(SupportedType.png, png)])])), at: now),
              case .inserted(let multiple) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, png)]), .init([.init(SupportedType.jpeg, jpeg)])])), at: now + 1),
              case .inserted(let text) = try await store.ingest(.init(payload: .init([.init([.init(SupportedType.string, Data("/tmp/like/a/path.png".utf8))])])), at: now + 2)
        else { throw StoreError.notFound }
        #if DEBUG
        let loads = await store.outputPayloadLoads
        #endif
        let first = try #require(try await store.imageByteCount(id: single, at: now + 10))
        #expect(first.bytes == Int64(png.count) && first.items == 1)
        let second = try #require(try await store.imageByteCount(id: multiple, at: now + 10))
        #expect(second.bytes == Int64(png.count + jpeg.count) && second.items == 2)
        #expect(try await store.imageByteCount(id: text, at: now + 10) == nil)
        #if DEBUG
        #expect(await store.outputPayloadLoads == loads)
        #endif
        // 原图字节与复制内容不变。
        let detail = try await store.detail(id: single, at: now + 10)
        #expect(detail.payload.items[0].representations.first { $0.type == SupportedType.png }?.data == png)
        #expect(ClipContentSize.stored(bytes: first.bytes, items: 1).label == HistoryViewModel.bytes(Int64(png.count)))
        #expect(ClipContentSize.stored(bytes: second.bytes, items: 2).label == "2 张 · 合计 " + HistoryViewModel.bytes(second.bytes))
    }

    /// N-01：文件逻辑大小、空文件 0 与未知区分、目录不递归、部分未知不伪装完整、符号链接按既有规则跟随。
    @Test func fileSizesDistinguishUnknownAndFolders() throws {
        let root = try Self.root(); defer { Self.unlock(root) }
        let fm = FileManager.default
        let big = root.appendingPathComponent("big.bin"), empty = root.appendingPathComponent("empty.txt")
        let folder = root.appendingPathComponent("folder"), missing = root.appendingPathComponent("missing.txt")
        let link = root.appendingPathComponent("link.bin")
        // 稀疏文件：逻辑 5 GiB，不实际写入，也不读取内容。
        #expect(fm.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 5 * 1_073_741_824); try handle.close()
        #expect(fm.createFile(atPath: empty.path, contents: Data()))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: folder.appendingPathComponent("inner"))
        try fm.createSymbolicLink(at: link, withDestinationURL: empty)
        #expect(ClipContentSize.measure([big]) == .files(known: 5 * 1_073_741_824, count: 1, unknown: 0, folders: 0))
        #expect(ClipContentSize.measure([big]).label == HistoryViewModel.bytes(5 * 1_073_741_824))
        let zero = ClipContentSize.measure([empty])
        #expect(zero == .files(known: 0, count: 1, unknown: 0, folders: 0) && zero.label == HistoryViewModel.bytes(0) && zero.label != "大小未知")
        #expect(ClipContentSize.measure([missing]).label == "大小未知")
        #expect(ClipContentSize.measure([folder]).label == "文件夹 · 大小未知")
        #expect(ClipContentSize.measure([big, empty, link]).label == "3 项 · 合计 " + HistoryViewModel.bytes(5 * 1_073_741_824))
        let partial = ClipContentSize.measure([big, missing, folder])
        #expect(partial.label == "3 项 · 部分未知（已知 " + HistoryViewModel.bytes(5 * 1_073_741_824) + "）")
        #expect(partial.detail?.contains("文件夹不统计内部文件") == true)
        #expect(ClipContentSize.measure([missing, folder]).label == "2 项 · 大小未知")
        #expect(ClipContentSize.measure([]).label == "大小未知")
        #expect(ClipContentSize.loading.label == nil)
        // 单位边界沿用项目二进制格式化器（1 KB = 1024 B）。
        #expect(HistoryViewModel.bytes(1023) != HistoryViewModel.bytes(1024))
        #expect(ClipContentSize.stored(bytes: 1024, items: 1).label == HistoryViewModel.bytes(1024))
        #expect(ClipContentSize.stored(bytes: Int64.max, items: 1).label?.isEmpty == false)
    }
    /// T4：文件卡 Footer 单文件只写大小，数量只出现在 Footer；不可读引用沿用原标签，by AI.Coding。
    @Test func fileFooterOmitsSingleItemCount() {
        let mb = HistoryViewModel.bytes(1_258_291)
        #expect(ClipCard.fileFooter(.files(known: 428_000, count: 1, unknown: 0, folders: 0)) == HistoryViewModel.bytes(428_000))
        #expect(ClipCard.fileFooter(.files(known: 1_258_291, count: 3, unknown: 0, folders: 0)) == "3 项 · " + mb)
        #expect(ClipCard.fileFooter(.files(known: 0, count: 1, unknown: 0, folders: 1)) == "文件夹")
        #expect(ClipCard.fileFooter(.files(known: 0, count: 2, unknown: 0, folders: 2)) == "2 个文件夹")
        #expect(ClipCard.fileFooter(.files(known: 0, count: 2, unknown: 2, folders: 0)) == "2 项 · 大小未知")
        #expect(ClipCard.fileFooter(.files(known: 0, count: 1, unknown: 1, folders: 0)) == "大小未知")
        #expect(ClipCard.fileFooter(.unknown) == "大小未知")
        #expect(ClipCard.fileFooter(.loading) == "文件引用")
    }
}
