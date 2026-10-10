// 真实NSPasteboard协议往返，仅专用命名板与合成内容，不代替目标应用M验收，by AI.Coding。
import AppKit
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor private final class NativeReadCounter: PasteboardAccess {
    let native:NativePasteboardAccess
    var reads:[String]=[]
    init(_ board:NSPasteboard) { native=NativePasteboardAccess(board) }
    var count:Int { native.count }
    var types:[[String]]? { native.types }
    func data(item:Int,type:String)->Data? { reads.append(type); return native.data(item:item,type:type) }
    func write(_ payload:ClipboardPayload,fingerprint:String)->Bool { native.write(payload,fingerprint:fingerprint) }
}
@MainActor struct NamedPasteboardTests {
    /// 全部七种受支持格式和多项顺序经过真实粘贴板服务器与SQLite后字节保持。
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func AC06_AC09_AC21_realNamedRoundTrip() async throws {
        let board=NSPasteboard(name:.init("local.localclip.test."+UUID().uuidString)); defer { board.releaseGlobally() }
        let first=NSPasteboardItem(); let second=NSPasteboardItem()
        let representations:[Representation]=[.init(SupportedType.string,Data("中文\nfixture".utf8)),.init(SupportedType.url,Data("https://example.invalid/path?a=1&b=2#section".utf8)),.init(SupportedType.rtf,Data("{\\rtf1\\ansi fixture \\b bold\\b0}".utf8)),.init(SupportedType.html,Data("<b>中文</b><br>fixture".utf8))]
        for value in representations { first.setData(value.data,forType:.init(value.type)) }
        var images:[Representation]=[]
        for type in [SupportedType.png,SupportedType.tiff,SupportedType.jpeg] { let data=try ImageFixtures.image(width:640,height:480,type:type); images.append(.init(type,data)); second.setData(data,forType:.init(type)) }
        board.clearContents(); #expect(board.writeObjects([first,second]))
        let client=MacPasteboardClient(access:NativePasteboardAccess(board))
        guard case .snapshot(let raw)=client.capture(after:-1,policy:.init()) else { Issue.record("真实命名板读取失败"); return }
        let snapshot=ContentDecoder.decode(raw)
        #expect(snapshot.payload.items.count == 2); #expect(snapshot.payload.kind == .mixed); #expect(snapshot.payload.plainText == nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=try HistoryStore(location:root,extractor:ContentDecoder.extract)
        guard case .inserted(let id)=try await store.ingest(snapshot,at:SystemClock().now()) else { Issue.record("fixture未保存"); return }
        let capture=CaptureCoordinator(board:client,store:store)
        let paste=PasteCoordinator(board:client,applications:MacApplicationClient(),store:store,capture:capture)
        #expect(await paste.perform(.init(ids:[id],action:.copy)) == .copied)
        let received=board.pasteboardItems!; #expect(received.count == 2)
        for (index,reps) in [representations,images].enumerated() { for rep in reps { #expect(received[index].data(forType:.init(rep.type)) == rep.data) } }
        capture.tick(); #expect(try await store.detail(id:id,at:SystemClock().now()).summary.copyCount == 1)
        board.clearContents(); #expect(board.setString("USER-AFTER-RESTORE",forType:.string)); capture.tick()
        let deadline=ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        #expect(try await store.search(.init()).items.count == 2)
        #expect(await paste.perform(.init(ids:[id],format:.plainText,action:.copy)) == .failed("所选内容包含无文本项目，不能纯文本输出；请使用原格式"))
        #expect(board.string(forType:.string) == "USER-AFTER-RESTORE")
        capture.stop()
    }
    /// 标记和协作来源经过真实服务器，敏感内容零正文读取、零SQL残留。
    @Test(.enabled(if:ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func AC10_AC18_AC22_realNamedPrivacy() async throws {
        let board=NSPasteboard(name:.init("local.localclip.private-test."+UUID().uuidString)); defer { board.releaseGlobally() }
        let item=NSPasteboardItem(); item.setString("SYNTHETIC-PRIVATE-ZERO-RESIDUE",forType:.string); item.setData(Data(),forType:.init("org.nspasteboard.ConcealedType"))
        board.clearContents(); #expect(board.writeObjects([item]))
        let counter=NativeReadCounter(board),client=MacPasteboardClient(access:counter)
        if case .skipped(.sensitive,_)=client.capture(after:-1,policy:.init()) {} else { Issue.record("真实类型标记未过滤") }
        #expect(counter.reads.isEmpty)
        let source=NSPasteboardItem(); source.setString("SYNTHETIC-EXCLUDED",forType:.string); source.setString("local.test.synthetic",forType:.init("org.nspasteboard.source"))
        board.clearContents(); #expect(board.writeObjects([source])); var policy=SettingsSnapshot(); policy.excludedBundleIDs.insert("local.test.synthetic")
        if case .skipped(.excluded,_)=client.capture(after:-1,policy:policy) {} else { Issue.record("真实协作来源排除失败") }
        #expect(!counter.reads.contains(SupportedType.string))
        board.clearContents(); #expect(board.setString("UNKNOWN-ALLOWED",forType:.string))
        guard case .snapshot(let unknown)=client.capture(after:-1,policy:policy) else { Issue.record("未知未保存"); return }
        #expect(unknown.source == .unknown)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let store=try HistoryStore(location:root); _ = try await store.ingest(unknown,at:SystemClock().now())
        let data=try Data(contentsOf:root.appendingPathComponent("History/history.sqlite"))
        #expect(!data.contains(Data("SYNTHETIC-PRIVATE-ZERO-RESIDUE".utf8))); #expect(!data.contains(Data("SYNTHETIC-EXCLUDED".utf8)))
    }
}
