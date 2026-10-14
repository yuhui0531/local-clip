// 输出预算前后同一合成载荷的测试宿主实测；不使用系统剪贴板，by AI.Coding。
import Foundation
import Darwin
import Testing
import LocalClipCore
@testable import LocalClipMac

private final class OutputFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UInt64] = []
    /// 读取本测试进程物理占用；5ms采样峰值不是理论峰值上界。
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { lock.lock(); samples.append(info.phys_footprint); lock.unlock() }
    }
    func values() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return samples }
}

@MainActor struct SpecifiedReviewOutputBenchmark {
    /// 52MiB原始图片表示仅用于输出资源测量，不是图像解码/GUI基准。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT_BENCHMARK"] == "1"))
    func batchOutputResourceSamples() async throws {
        let output = try #require(ProcessInfo.processInfo.environment["LOCALCLIP_REVIEW_OUTPUT_PATH"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), raw = RawBoard()
        let board = MacPasteboardClient(access: raw), capture = CaptureCoordinator(board: board, store: store)
        let paste = PasteCoordinator(board: board, applications: FakeApplications(), store: store, capture: capture)
        var ids: [ClipID] = []
        for byte in [UInt8(21), 22] {
            let payload = ClipboardPayload([.init([.init(SupportedType.png, Data(repeating: byte, count: 26 * Int(MiB)))])])
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: SystemClock().now()) else { throw StoreError.notFound }
            ids.append(id)
        }
        var samples: [[String: Any]] = []
        for _ in 0..<10 {
            raw.user("unchanged synthetic clipboard")
            let count = raw.count, memory = OutputFootprintSamples()
            memory.sample()
            let observer = Task.detached {
                while !Task.isCancelled {
                    memory.sample()
                    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                }
            }
            let start = ContinuousClock.now
            let result = await paste.perform(.init(ids: ids))
            let elapsed = start.duration(to: .now).components
            memory.sample(); observer.cancel(); await observer.value
            samples.append(["milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                            "footprintBytes": memory.values(), "result": result.message, "published": raw.count != count])
        }
        try JSONSerialization.data(withJSONObject: ["inputBytes": 52 * MiB, "samples": samples], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
