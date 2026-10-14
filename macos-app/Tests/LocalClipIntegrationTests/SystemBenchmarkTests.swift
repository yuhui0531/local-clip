// 真正命名NSPasteboard与Release生产服务压力/空闲基准；不等价于目标应用接收，by AI.Coding。
import AppKit
import Darwin
import Testing
import LocalClipCore
@testable import LocalClipMac
@MainActor struct SystemBenchmarkTests {
    /// 在专用pasteboard采集，按四种速率记录丢失和明确跳过，再测10分钟空闲CPU。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_SYSTEM_BENCHMARK"] == "1"))
    func AC16_namedPasteboardStressAndIdle() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(environment["LOCALCLIP_BENCHMARK_OUTPUT"], "Required benchmark environment: LOCALCLIP_BENCHMARK_OUTPUT"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories:true)
        let source = URL(fileURLWithPath:try #require(environment["LOCALCLIP_BENCHMARK_FIXTURE"], "Required benchmark environment: LOCALCLIP_BENCHMARK_FIXTURE"))
        let root = output.appendingPathComponent("working-store")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source.appendingPathComponent("fixture-store/History/history.sqlite"),to:root.appendingPathComponent("History/history.sqlite"))
        let manifest = try Data(contentsOf:source.appendingPathComponent("fixture-manifest.json")); try manifest.write(to:output.appendingPathComponent("fixture-manifest.json"))
        let store = try HistoryStore(location:root,extractor:ContentDecoder.extract)
        let board = NSPasteboard(name:.init("local.localclip.performance." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let capture = CaptureCoordinator(board:MacPasteboardClient(access:NativePasteboardAccess(board)),store:store)
        try await capture.start(); defer { capture.stop() }
        var ignores:[String:Int] = [:]; var lastIgnore:Instant?
        capture.onState = { _ in if let (reason,time) = capture.lastIgnored, time != lastIgnore { lastIgnore=time; ignores[reason.rawValue,default:0] += 1 } }
        var phases:[[String:Any]] = []
        for interval in [1000,500,200,50] {
            let prefix = "STRESS-\(interval)-"; var writeTimes:[Double] = []; let phaseBegan=ContinuousClock.now
            let before = ignores
            for index in 0..<100 {
                board.clearContents(); #expect(board.setString(prefix + String(index),forType:.string))
                writeTimes.append(Self.milliseconds(phaseBegan.duration(to:.now)))
                try await Task.sleep(for:.milliseconds(interval))
            }
            // 最后一项及有界队列完成，等待上限20秒；不把仍未完成的输入偷偷丢掉。
            var previous = -1; var stable = 0; var saved = 0
            for _ in 0..<40 {
                saved = try await Self.count(store,prefix)
                stable = saved == previous ? stable + 1 : 0; previous=saved
                if stable >= 4 { break }
                try await Task.sleep(for:.milliseconds(500))
            }
            let skipped=ignores.reduce(into:[String:Int]()) { result,pair in let value=pair.value-(before[pair.key] ?? 0); if value>0 { result[pair.key]=value } }
            let explicit = skipped.values.reduce(0,+)
            phases.append(["intervalMs":interval,"inputCount":100,"savedCount":saved,"deduplicatedCount":0,"explicitSkips":skipped,"unobservedChanges":max(0,100-saved-explicit),"sourceWriteCompletionMs":writeTimes,"elapsedMs":Self.milliseconds(phaseBegan.duration(to:.now))])
            try Self.write(["layer":"real named NSPasteboard + production capture/store, no UI", "pollMs":200,"phases":phases],to:output.appendingPathComponent("stress.json"))
            print("stress interval=\(interval) inputs=100 saved=\(saved) explicit=\(explicit) unobserved=\(max(0,100-saved-explicit))")
        }
        // 新的GUI进程单独测空闲；此开关只重跑压力，不把测试宿主空闲冒充GUI资源，by AI.Coding。
        if environment["LOCALCLIP_SYSTEM_STRESS_ONLY"] == "1" {
            try Self.write(["stressComplete":true,"idleMeasuredHere":false],to:output.appendingPathComponent("stress-only.json"))
            return
        }
        try await Task.sleep(for:.seconds(10))
        var samples:[[String:Any]] = []; var previous=Self.resources(); var instant=ContinuousClock.now
        for index in 0..<120 {
            try await Task.sleep(for:.seconds(5))
            let current=Self.resources(); let elapsed=Self.milliseconds(instant.duration(to:.now))/1000
            samples.append(["index":index,"elapsedSeconds":elapsed,"cpuPercent":(current.cpu-previous.cpu)/elapsed*100,"peakResidentBytes":current.memory,"voluntaryContextSwitches":current.switches-previous.switches])
            previous=current; instant = .now
            try Self.write(["layer":"Release Swift Testing host with production capture/store, excludes actual app UI runtime","warmupSeconds":10,"durationSamplesSeconds":600,"sampleIntervalSeconds":5,"samples":samples,"energy":"unavailable","wakeups":"unavailable; context switches are reported separately"],to:output.appendingPathComponent("idle-resources.json"))
        }
    }
    /// 完整分页统计，不将第一页50条当作全部保存数。
    private static func count(_ store:HistoryStore,_ literal:String) async throws -> Int {
        var page = try await store.search(.init(literal)); var count=page.items.count
        while let next=page.next { page = try await store.search(.init(literal,cursor:next)); count += page.items.count }
        return count
    }
    /// 单调时间转毫秒。
    private static func milliseconds(_ duration:Duration) -> Double { Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15 }
    /// rusage测量当前测试宿主CPU与峰值RSS，不能冒充正式app进程。
    private static func resources() -> (cpu:Double,memory:Int64,switches:Int64) {
        var value=rusage(); getrusage(RUSAGE_SELF,&value)
        let cpu=Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec)/1e6
        return (cpu,Int64(value.ru_maxrss),Int64(value.ru_nvcsw))
    }
    /// 每阶段落盘原始样本，异常退出保留已经实测的部分。
    private static func write(_ object:Any,to url:URL) throws { try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
}
