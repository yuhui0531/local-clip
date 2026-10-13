import AppKit
import ImageIO
import Testing
@testable import LocalClipCore
@testable import LocalClipMac

/// Real encoded images; TIFF pages and metadata deliberately carry information absent from PNG.
private enum PreservationImages {
    static func tiff(pages: Int = 1, width: Int = 32, height: Int = 24) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, SupportedType.tiff as CFString, pages, nil))
        for page in 0..<pages {
            let png = try ImageFixtures.image(width: width + page, height: height + page)
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFCompression: 1,
                kCGImagePropertyTIFFImageDescription: "Original TIFF page \(page)",
                kCGImagePropertyTIFFArtist: "LocalClip regression fixture"
            ]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let data = output as Data
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == pages)
        for page in 0..<pages {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, page, nil))
            #expect(image.width == width + page && image.height == height + page)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, page, nil) as? [CFString: Any])
            let metadata = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect(metadata[kCGImagePropertyTIFFImageDescription] as? String == "Original TIFF page \(page)")
        }
        return data
    }

    static func payload(pages: Int = 1, invalidPNG: Bool = false) throws -> ClipboardPayload {
        .init([.init([
            .init(SupportedType.png, invalidPNG ? Data("invalid PNG".utf8) : try ImageFixtures.image(width: 32, height: 24)),
            .init(SupportedType.tiff, try tiff(pages: pages))
        ])])
    }

    static func highDepthTIFF() throws -> Data {
        let provider = try #require(CGDataProvider(data: Data((0..<512).map { UInt8($0 % 251) }) as CFData))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 16, bitsPerPixel: 16,
                                        bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: .byteOrder16Little, provider: provider, decode: nil,
                                        shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, SupportedType.tiff as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = output as Data
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.bitsPerComponent == 16)
        return data
    }
}

@MainActor struct ImagePreservationTests {
    @Test(arguments: [1, 2])
    func realImagesSurviveCaptureStorageMaintenanceAndReopen(pages: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try PreservationImages.payload(pages: pages)
        let raw = RawBoard()
        raw.items = payload.items.map { Dictionary(uniqueKeysWithValues: $0.representations.map { ($0.type, $0.data) }) }
        let client = MacPasteboardClient(access: raw)
        guard case .snapshot(let snapshot) = await client.captureAsync(after: -1, policy: .init()) else {
            Issue.record("Image capture failed"); return
        }
        #expect(snapshot.payload.canonicalData == payload.canonicalData)
        let store = try HistoryStore(location: root), now = SystemClock().now()
        guard case .inserted(let id) = try await store.ingest(snapshot, at: now) else {
            Issue.record("Image insertion failed"); return
        }
        let category = try await store.createCategory(name: "Preserve images", colorHex: "34C759")
        _ = try await store.apply(store.preview(.category([id], category.id, true)).token)
        try await store.renameClip(id: id, title: "Original image")
        let before = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        #expect(try await store.compactRedundantImages() == 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == before)
        let capture = CaptureCoordinator(board: client, store: store)
        let model = HistoryViewModel(store: store, capture: capture,
                                    paste: PasteCoordinator(board: client, applications: FakeApplications(), store: store, capture: capture),
                                    derived: DerivedContentService(store: store))
        await model.maintenance()
        let reopened = try HistoryStore(location: root)
        let detail = try await reopened.detail(id: id, at: now)
        #expect(detail.payload.canonicalData == payload.canonicalData)
        #expect(detail.categoryIDs == [category.id])
        #expect(detail.summary.title == "Original image")
        #expect(try await reopened.ingest(.init(payload: payload), at: now + 1) == .deduplicated(id))
        #expect(try await reopened.detail(id: id, at: now + 1).summary.copyCount == 2)
    }

    @Test func deduplicationIncludesEveryOriginalRepresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let original = try PreservationImages.payload()
        var multipage = original
        multipage.items[0].representations[1].data = try PreservationImages.tiff(pages: 2)
        var differentImage = original
        differentImage.items[0].representations[1].data = try PreservationImages.tiff(width: 17, height: 19)
        var highDepth = original
        highDepth.items[0].representations[1].data = try PreservationImages.highDepthTIFF()
        let pngOnly = ClipboardPayload([.init([original.items[0].representations[0]])])
        let tiffOnly = ClipboardPayload([.init([original.items[0].representations[1]])])
        let invalidPNG = try PreservationImages.payload(invalidPNG: true)
        let payloads = [original, multipage, differentImage, highDepth, pngOnly, tiffOnly, invalidPNG]
        var ids: [ClipID] = []
        for (index, payload) in payloads.enumerated() {
            guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now + Int64(index)) else {
                Issue.record("Distinct original representations were merged"); continue
            }
            ids.append(id)
            var reordered = payload
            reordered.items[0].representations.reverse()
            #expect(try await store.ingest(.init(payload: reordered), at: now + 10) == .deduplicated(id))
            #expect(try await store.loadPayload(id: id, at: now + 10).canonicalData == payload.canonicalData)
        }
        #expect(Set(ids).count == payloads.count)
        let db = try SQLiteConnection(root.appendingPathComponent("History/history.sqlite"), readonly: true)
        defer { try? db.close() }
        // Identical PNG/TIFF bytes still share BLOBs even when complete payload identities differ.
        let uniqueBlobs = Set(payloads.flatMap(\.items).flatMap(\.representations).map { ContentFingerprint.hash($0.data) })
        #expect(try db.scalarInt("SELECT COUNT(*) FROM blobs") == Int64(uniqueBlobs.count))
        #expect(try db.scalarText("PRAGMA integrity_check") == "ok")
        #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
    }

    @Test func quotaFailureDoesNotStripTIFFOrDeleteExistingHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 2 * MiB
        let store = try HistoryStore(location: root, initialSettings: settings), now = SystemClock().now()
        let original = try PreservationImages.payload(pages: 2)
        guard case .inserted(let id) = try await store.ingest(.init(payload: original), at: now) else {
            Issue.record("Fixture insertion failed"); return
        }
        var large = original
        large.items[0].representations[1].data = try PreservationImages.tiff(width: 1024, height: 1024)
        #expect(large.byteCount > settings.quotaBytes)
        let before = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        do {
            _ = try await store.ingest(.init(payload: large), at: now + 1)
            Issue.record("Oversized original was silently reduced to PNG")
        } catch { #expect(error as? StoreError == .quotaExceeded) }
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == before)
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == original.canonicalData)
        #expect(try await store.usage().measuredTotal <= settings.quotaBytes)
    }

    @Test func combinedCaptureLimitIsAtomic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var payload = try PreservationImages.payload()
        // Valid TIFF plus trailing padding exercises the exact byte boundary without huge decoded pixels.
        let pngSize = payload.items[0].representations[0].data.count
        var tiff = payload.items[0].representations[1].data
        tiff.append(Data(count: Int(50 * MiB) - pngSize - tiff.count))
        let source = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        payload.items[0].representations[1].data = tiff
        #expect(payload.byteCount == 50 * MiB)
        let raw = RawBoard(), client = MacPasteboardClient(access: raw)
        raw.items = [[SupportedType.png: payload.items[0].representations[0].data, SupportedType.tiff: tiff]]
        guard case .snapshot(let exact) = await client.captureAsync(after: -1, policy: .init()) else {
            Issue.record("Exact 50 MiB capture rejected"); return
        }
        #expect(exact.payload.canonicalData == payload.canonicalData)
        let store = try HistoryStore(location: root), now = SystemClock().now()
        guard case .inserted(let id) = try await store.ingest(exact, at: now) else {
            Issue.record("Exact 50 MiB ingest rejected"); return
        }
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == payload.canonicalData)
        let before = try Data(contentsOf: root.appendingPathComponent("History/history.sqlite"))
        payload.items[0].representations[1].data.append(0)
        raw.items[0][SupportedType.tiff] = payload.items[0].representations[1].data
        raw.count += 1
        if case .skipped(.tooLarge, _) = client.capture(after: -1, policy: .init()) {} else { Issue.record("Synchronous capture lost TIFF to fit limit") }
        if case .skipped(.tooLarge, _) = await client.captureAsync(after: -1, policy: .init()) {} else { Issue.record("Async capture lost TIFF to fit limit") }
        #expect(try await store.ingest(.init(payload: payload), at: now + 1) == .skipped(.tooLarge))
        #expect(try Data(contentsOf: root.appendingPathComponent("History/history.sqlite")) == before)
    }

    @Test func quotaEvictsOrdinaryRecordsWithoutStrippingProtectedImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = SettingsSnapshot(); settings.quotaBytes = 2 * MiB
        let store = try HistoryStore(location: root, initialSettings: settings), now = SystemClock().now()
        func image(_ width: Int, _ height: Int) throws -> ClipboardPayload {
            var payload = try PreservationImages.payload()
            payload.items[0].representations[1].data = try PreservationImages.tiff(width: width, height: height)
            return payload
        }
        let protectedPayload = try image(256, 256), ordinaryPayload = try image(512, 512), incoming = try image(640, 512)
        guard case .inserted(let protectedID) = try await store.ingest(.init(payload: protectedPayload), at: now) else {
            Issue.record("Protected fixture insertion failed"); return
        }
        _ = try await store.apply(store.preview(.favorite(protectedID, true)).token)
        let category = try await store.createCategory(name: "Protected", colorHex: "34C759")
        _ = try await store.apply(store.preview(.category([protectedID], category.id, true)).token)
        guard case .inserted(let ordinaryID) = try await store.ingest(.init(payload: ordinaryPayload), at: now + 1) else {
            Issue.record("Ordinary fixture insertion failed"); return
        }
        #expect(try await store.search(.init()).items.count == 2)
        guard case .inserted(let incomingID) = try await store.ingest(.init(payload: incoming), at: now + 2) else {
            Issue.record("Quota eviction failed"); return
        }
        #expect(Set(try await store.search(.init()).items.map(\.id)) == [protectedID, incomingID])
        #expect(try await store.search(.init()).items.contains { $0.id == ordinaryID } == false)
        #expect(try await store.loadPayload(id: protectedID, at: now + 2).canonicalData == protectedPayload.canonicalData)
        #expect(try await store.loadPayload(id: incomingID, at: now + 2).canonicalData == incoming.canonicalData)
        #expect(try await store.detail(id: protectedID, at: now + 2).categoryIDs == [category.id])
        #expect(try await store.usage().measuredTotal <= settings.quotaBytes)
    }

    @Test func captureLimitCountsRealImageBytesAcrossItems() async throws {
        var payload = try PreservationImages.payload()
        payload.items[0].representations[1].data = try PreservationImages.tiff(width: 2048, height: 1024)
        // No padding: seven actual encoded images exceed the aggregate cap, each is individually below it.
        #expect(payload.byteCount < 50 * MiB)
        payload.items = Array(repeating: payload.items[0], count: 7)
        #expect(payload.byteCount > 50 * MiB)
        let raw = RawBoard(), client = MacPasteboardClient(access: raw)
        raw.items = payload.items.map { Dictionary(uniqueKeysWithValues: $0.representations.map { ($0.type, $0.data) }) }
        if case .skipped(.tooLarge, _) = await client.captureAsync(after: -1, policy: .init()) {} else {
            Issue.record("Aggregate capture limit omitted TIFF bytes")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        #expect(try await store.ingest(.init(payload: payload), at: SystemClock().now()) == .skipped(.tooLarge))
        #expect(try await store.search(.init()).items.isEmpty)
    }

    @Test(arguments: [false, true])
    func selfWritesAvoidImageBodyReadsAndDoNotSwallowNextCopy(asynchronous: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = RawBoard(), client = MacPasteboardClient(access: raw), store = try HistoryStore(location: root)
        let capture = CaptureCoordinator(board: client, store: store)
        defer { capture.stop() }
        let payload = try PreservationImages.payload()
        capture.recordOwnWrite(client.write(payload, fingerprint: payload.fingerprint))
        if asynchronous { await capture.poll() } else { capture.tick() }
        #expect(capture.lastIgnored?.0 == .selfWrite)
        #expect(raw.reads == [NativePasteboardAccess.ownType])
        #expect(try await store.search(.init()).items.isEmpty)
        raw.user("USER-AFTER-IMAGE")
        if asynchronous { await capture.poll() } else { capture.tick() }
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.map(\.preview) == ["USER-AFTER-IMAGE"])
    }

    @Test func userCopyDuringSelfWriteMarkerReadIsNotSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = RawBoard(), client = MacPasteboardClient(access: raw), store = try HistoryStore(location: root)
        let capture = CaptureCoordinator(board: client, store: store)
        defer { capture.stop() }
        let payload = try PreservationImages.payload()
        capture.recordOwnWrite(client.write(payload, fingerprint: payload.fingerprint))
        raw.onRead = { _, type in
            if type == NativePasteboardAccess.ownType {
                raw.onRead = nil; raw.user("USER-DURING-MARKER")
                // A copied marker can still match while the generation has changed.
                raw.items[0][NativePasteboardAccess.ownType] = Data(payload.fingerprint.utf8)
            }
        }
        await capture.poll()
        let deadline = ContinuousClock.now + .seconds(3)
        while try await store.search(.init()).items.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.search(.init()).items.map(\.preview) == ["USER-DURING-MARKER"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"), arguments: [false, true])
    func nativeRoundTripPreservesMultipageTIFF(invalidPNG: Bool) async throws {
        let board = NSPasteboard(name: .init("local.localclip.image-preservation." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let payload = try PreservationImages.payload(pages: 2, invalidPNG: invalidPNG)
        let item = NSPasteboardItem()
        for representation in payload.items[0].representations { #expect(item.setData(representation.data, forType: .init(representation.type))) }
        board.clearContents(); #expect(board.writeObjects([item]))
        let client = MacPasteboardClient(access: NativePasteboardAccess(board))
        guard case .snapshot(let snapshot) = await client.captureAsync(after: -1, policy: .init()) else {
            Issue.record("Native image capture failed"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        guard case .inserted(let id) = try await store.ingest(ContentDecoder.decode(snapshot), at: now) else {
            Issue.record("Native image insertion failed"); return
        }
        let capture = CaptureCoordinator(board: client, store: store)
        defer { capture.stop() }
        let paste = PasteCoordinator(board: client, applications: FakeApplications(), store: store, capture: capture)
        #expect(await paste.perform(.init(ids: [id], action: .copy)) == .copied)
        let received = try #require(board.pasteboardItems?.first)
        for representation in payload.items[0].representations {
            #expect(received.data(forType: .init(representation.type)) == representation.data)
        }
        let restoredTIFF = try #require(received.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(restoredTIFF as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"))
    func pngOnlyHistoryStillProvidesTIFFOnDemand() throws {
        let board = NSPasteboard(name: .init("local.localclip.png-compatibility." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let png = try ImageFixtures.image(width: 32, height: 24)
        let payload = ClipboardPayload([.init([.init(SupportedType.png, png)])])
        #expect(NativePasteboardAccess(board).write(payload, fingerprint: payload.fingerprint))
        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: .png) == png)
        let generated = try #require(item.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(generated as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 32 && image.height == 24)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"), arguments: ["png", "tiff", "jpeg", "high-depth", "paired"])
    func imageFilePromisePreservesOriginalBytes(format: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let type = format == "tiff" || format == "high-depth" ? SupportedType.tiff : format == "jpeg" ? SupportedType.jpeg : SupportedType.png
        let data = format == "high-depth" ? try PreservationImages.highDepthTIFF() : type == SupportedType.tiff ? try PreservationImages.tiff(pages: 2) : try ImageFixtures.image(width: 32, height: 24, type: type)
        var payload = ClipboardPayload([.init([.init(type, data)])])
        if format == "paired" { payload.items[0].representations.append(.init(SupportedType.tiff, try PreservationImages.tiff(pages: 2))) }
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now) else { Issue.record("Fixture rejected"); return }
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { _ in })
        let provider = try #require(writers.first as? NSFilePromiseProvider)
        let delegate = try #require(provider.delegate)
        #expect(provider.fileType == type)
        let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
        let suffix = type == SupportedType.tiff ? "tiff" : type == SupportedType.jpeg ? "jpg" : "png"
        #expect(name.hasSuffix("." + suffix))
        let destination = root.appendingPathComponent(name)
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in continuation.resume(returning: error) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == data)
        #expect(try await store.loadPayload(id: id, at: now).canonicalData == payload.canonicalData)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOCALCLIP_NAMED_TEST"] == "1"), arguments: ["cancelled", "deleted", "quota", "existing-file"])
    func imageFilePromiseFailureLeavesDestinationAndHistorySafe(reason: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let payload = ClipboardPayload([.init([.init(SupportedType.tiff, try PreservationImages.tiff(pages: 2))])])
        guard case .inserted(let id) = try await store.ingest(.init(payload: payload), at: now) else { Issue.record("Fixture rejected"); return }
        var access: ClipExportAccess?
        let writers = try await ContentExportProvider.writers(ids: [id], store: store, token: "test", register: { access = $0 })
        let provider = try #require(writers.first as? NSFilePromiseProvider), delegate = try #require(provider.delegate)
        let destination = root.appendingPathComponent("received.tiff")
        let existing = Data("Do not overwrite".utf8)
        switch reason {
        case "cancelled": access?.cancel()
        case "deleted": _ = try await store.apply(store.preview(.delete([id])).token)
        case "quota":
            // Exhaust only the export-lease budget; history must not be evicted to make room.
            let exports = root.appendingPathComponent("Exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 50 * 1024 * 1024).write(to: exports.appendingPathComponent("occupied.png"))
        default: try existing.write(to: destination)
        }
        let error: Error? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
        #expect(error != nil)
        if reason == "existing-file" { #expect(try Data(contentsOf: destination) == existing) }
        else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
        if reason != "deleted" { #expect(try await store.loadPayload(id: id, at: now).canonicalData == payload.canonicalData) }
        if reason == "quota" { #expect(error as? StoreError == .quotaExceeded) }
    }

    @Test func imageExportRejectsUnsafeExtensionWithoutWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root)
        do {
            _ = try await store.writeExport(Data(), id: "unused", revision: 0, fileExtension: "../escape")
            Issue.record("Unsafe export extension accepted")
        } catch { #expect(error as? StoreError == .invalidSettings) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Exports").path))
    }

}
