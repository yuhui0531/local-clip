// 固定数据集的真实 SQLite 服务基准；不冒充界面端到端性能，by AI.Coding。
import Foundation
import CryptoKit
import AppKit
import ImageIO
import Testing
@testable import LocalClipCore
struct BenchmarkGenerator {
    static let version = "localclip-fixtures-v2"
    /// 固定种子像素，真实 PNG/TIFF/JPEG 编码，每张内容不同。
    static func image(_ index: Int) throws -> (String, Data) {
        let formatIndex = index % 100
        let type = formatIndex < 20 ? SupportedType.png : formatIndex < 30 ? SupportedType.tiff : SupportedType.jpeg
        let width = 1920, height = 1080
        var state = UInt64(0xC11F + index)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            if pixel % 2 == 0 { state = state &* 6364136223846793005 &+ 1442695040888963407 }
            let gray = UInt8(truncatingIfNeeded: state >> 40) & 0x7F
            bytes[pixel * 4] = gray; bytes[pixel * 4 + 1] = gray; bytes[pixel * 4 + 2] = gray
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { throw StoreError.ioFailure }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.ioFailure }
        return (type, output as Data)
    }
    /// 90%小文本、9%中等、1%长文；尾部查询不能被摘要截断。
    static func text(_ index: Int) -> String {
        let stems = ["今天整理需求，明天处理代码。", "The local clipboard keeps original representations.",
            "https://example.invalid/path?a=1&b=2#section", "let foo_bar = 50%; a->b; \"value\"; path\\test\n"]
        let base = "fixture-\(index) " + stems[index % 4] + "\n"
        let desired = index < 9000 ? 256 + index % 1500 : index < 9900 ? 2048 + index % 14000 : 16384 + index % 100000
        return String(repeating: base, count: max(1, desired / base.utf8.count)) + " END-\(index)"
    }
    /// 批量创建纯测试数据库，避免用一万次候选替换测量fixture生成成本。
    static func seed(_ root: URL, output: URL) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"))
        try db.exec("PRAGMA auto_vacuum=FULL"); try db.configure(); try Schema.create(db, settings: .init())
        try db.exec("BEGIN IMMEDIATE")
        let now = SystemClock().now(); var hash = SHA256(); var textBytes: Int64 = 0; var imageBytes: Int64 = 0
        var imageManifest: [[String: Any]] = []
        for index in 0..<10100 {
            let type: String, data: Data, text: String
            if index < 10000 { type = SupportedType.string; text = Self.text(index); data = Data(text.utf8); textBytes += Int64(data.count) }
            else { (type, data) = try image(index - 10000); text = ""; imageBytes += Int64(data.count)
                imageManifest.append(["index": index - 10000, "type": type, "bytes": data.count, "sha256": ContentFingerprint.hash(data), "width":1920,"height":1080]) }
            let payload = ClipboardPayload([.init([.init(type, data)])]); let id = "benchmark-\(index)"; let digest = ContentFingerprint.hash(data)
            hash.update(data: Data(type.utf8)); hash.update(data: data)
            try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceBundleID,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,?, ?,?,?,?,?,?)", [.text(id), .text(payload.fingerprint), .integer(now), .integer(now + Int64(index)), .integer(1), .text(payload.kind.rawValue), .integer(index % 20 == 0 ? 1 : 0), .null, .text("来源未知"), .text("unknown"), .text(String(text.prefix(180)))])
            try db.run("INSERT INTO items VALUES(?,?,?)", [.text(id), .integer(0), .text("[\"\(type)\"]")])
            try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(data.count)), .blob(data)])
            try db.run("INSERT INTO representations VALUES(?,?,?,?)", [.text(id), .integer(0), .text(type), .text(digest)])
            if !text.isEmpty { try db.run("INSERT INTO text_content VALUES(?,?,?,?)", [.text(id), .integer(0), .text(text), .text(SearchNormalizer.normalize(text))]) }
        }
        try db.exec("COMMIT"); #expect(try db.scalarText("PRAGMA integrity_check") == "ok"); try db.close()
        let manifest: [String: Any] = ["generator":version,"seed":"0xC11F","texts":10000,"distribution":[9000,900,100],"textBytes":textBytes,"images":imageManifest,"imageBytes":imageBytes,"datasetHash":hash.finalize().map { String(format:"%02x", $0) }.joined(),"sqliteBytes":try CommitStrategy.bytes(root.appendingPathComponent("History"))]
        try write(manifest, to: output.appendingPathComponent("fixture-manifest.json")); return manifest
    }
    /// 原始样本与nearest-rank分位一起保留。
    static func write(_ object: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: url) }
    static func metrics(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted(); return ["samplesMs":samples,"n":samples.count,"p95Ms":sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],"meanMs":samples.reduce(0,+)/Double(samples.count),"maxMs":sorted.last!]
    }
}
struct BenchmarkTests {
    /// 正式优化构建服务层计时；界面防抖、绘制和系统轮询另行验收。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_BENCHMARK"] == "1"))
    func AC16_serviceBenchmark() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOCALCLIP_BENCHMARK_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("fixture-store")
        let manifest: [String:Any]
        if let reused = ProcessInfo.processInfo.environment["LOCALCLIP_BENCHMARK_REUSE"] {
            let source = URL(fileURLWithPath: reused)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent("fixture-store/History/history.sqlite"), to: root.appendingPathComponent("History/history.sqlite"))
            manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("fixture-manifest.json"))) as! [String:Any]
            try BenchmarkGenerator.write(manifest, to: output.appendingPathComponent("fixture-manifest.json"))
        } else { manifest = try BenchmarkGenerator.seed(root, output: output) }
        let working = output.appendingPathComponent("working-store")
        try FileManager.default.createDirectory(at:working.appendingPathComponent("History"),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:root.appendingPathComponent("History/history.sqlite"),to:working.appendingPathComponent("History/history.sqlite"))
        let store = try HistoryStore(location: working)
        let queries = ["需求", "代", "foo_bar", "50%", "a->b", "?a=1&b=2", "END-9999", "fixture-1234", "missing-literal", "The local"]
        let count = ProcessInfo.processInfo.environment["LOCALCLIP_BENCHMARK_PHASE"] == "baseline" ? 10 : 200
        var search: [Double] = [], empty: [Double] = [], writes: [Double] = [], imageWrites: [Double] = [], quotaWrites: [Double] = []
        var newImageManifest: [[String: Any]] = []
        for index in 0..<count {
            let began = ContinuousClock.now; _ = try await store.search(.init(queries[index % queries.count]))
            let elapsed = began.duration(to: .now); search.append(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)
        }
        for _ in 0..<count {
            let began = ContinuousClock.now; _ = try await store.search(.init())
            let elapsed = began.duration(to: .now); empty.append(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)
        }
        if count == 200 {
            for index in 0..<200 {
                let began = ContinuousClock.now
                _ = try await store.ingest(.init(payload:.init([.init([.init(SupportedType.string, Data("performance-write-\(index)".utf8))])])), at: SystemClock().now())
                let elapsed = began.duration(to: .now); writes.append(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)
            }
            for index in 0..<20 {
                let fixtureIndex = 100 + (index * 13) % 100
                let (type, data) = try BenchmarkGenerator.image(fixtureIndex)
                let payload = ClipboardPayload([.init([.init(type, data)])])
                let began = ContinuousClock.now
                let result = try await store.ingest(.init(payload:payload),at:SystemClock().now())
                let elapsed = began.duration(to:.now); imageWrites.append(Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15)
                if case .inserted = result {} else { Issue.record("新图片被错误去重或跳过") }
                newImageManifest.append(["fixtureIndex":fixtureIndex,"type":type,"bytes":data.count,"sha256":ContentFingerprint.hash(data),"width":1920,"height":1080])
            }
            try BenchmarkGenerator.write(["generator":"localclip-new-image-samples-v1","operation":"20 distinct new insertions; encode before timer","images":newImageManifest],to:output.appendingPathComponent("new-image-manifest.json"))
            // 单独的500MiB库：约480MiB原始载荷，真实文件确认90%–98%，不混入普通样本。
            let quotaStore = try HistoryStore(location:output.appendingPathComponent("quota-store"))
            for index in 0..<12 {
                let result = try await quotaStore.ingest(.init(payload:.init([.init([.init(SupportedType.png,Data(repeating:UInt8(100+index),count:40*1_048_576))])])),at:SystemClock().now())
                if index < 5, case .inserted(let id)=result { let p=try await quotaStore.preview(.favorite(id,true)); _ = try await quotaStore.apply(p.token) }
            }
            let usage = try await quotaStore.usage()
            try BenchmarkGenerator.write(["quota":500*MiB,"physicalBytes":usage.measuredTotal,"ratio":Double(usage.measuredTotal)/Double(500*MiB),"favoriteBytes":usage.favoritePayload,"generator":"5 favorites + 7 ordinary, distinct 40MiB payloads"],to:output.appendingPathComponent("quota-manifest.json"))
            #expect(usage.measuredTotal >= 450*MiB && usage.measuredTotal <= 490*MiB)
            for index in 0..<30 {
                let input=ClipboardSnapshot(payload:.init([.init([.init(SupportedType.png,Data(repeating:UInt8(20+index),count:20*1_048_576))])]))
                let began=ContinuousClock.now; _ = try await quotaStore.ingest(input,at:SystemClock().now())
                let elapsed=began.duration(to:.now); quotaWrites.append(Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15)
            }
        }
        var report: [String:Any] = ["layer":"SQLite service only, excludes UI and capture polling", "build":"Release", "datasetHash":manifest["datasetHash"]!, "search":BenchmarkGenerator.metrics(search),"firstPage":BenchmarkGenerator.metrics(empty),"queries":queries,"method":"monotonic ContinuousClock, nearest-rank ceil(0.95*n)"]
        if !writes.isEmpty { report["textCommit"] = BenchmarkGenerator.metrics(writes) }
        if !imageWrites.isEmpty { report["imageCommit"] = BenchmarkGenerator.metrics(imageWrites); report["imageOperation"] = "20 distinct new encoded image insertions" }
        if !quotaWrites.isEmpty { report["quotaCommit"] = BenchmarkGenerator.metrics(quotaWrites) }
        try BenchmarkGenerator.write(report, to: output.appendingPathComponent("service-results.json"))
        print("AC16 service samples=\(count) searchP95=\(BenchmarkGenerator.metrics(search)["p95Ms"]!)ms firstPageP95=\(BenchmarkGenerator.metrics(empty)["p95Ms"]!)ms")
    }
}
