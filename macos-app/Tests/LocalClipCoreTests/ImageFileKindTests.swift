// 全部为图片的文件引用同时出现在文件与图片筛选中，by AI.Coding。
import Foundation
import Testing
@testable import LocalClipCore
struct ImageFileKindTests {
    private func files(_ paths: [String]) -> ClipboardSnapshot {
        ClipboardSnapshot(payload: .init(paths.map { .init([.init(SupportedType.fileURL, Data(URL(fileURLWithPath: $0).absoluteString.utf8))]) }))
    }
    @Test func imageFileRule() {
        for path in ["/a/photo.png", "/a/PHOTO.JPG", "/a/shot.heic", "/a/scan.tiff", "/a/anim.gif"] { #expect(ClipboardPayload.isImageFile(path), "\(path)") }
        for path in ["/a/icon.svg", "/a/doc.pdf", "/a/notes.txt", "/a/noext", "/a/README.md"] { #expect(!ClipboardPayload.isImageFile(path), "\(path)") }
    }
    @Test func imageFilesAppearInImageAndFileFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(location: root), now = SystemClock().now()
        let single = insertedID(try await store.ingest(files(["/tmp/a.png"]), at: now))
        let several = insertedID(try await store.ingest(files(["/tmp/b.jpg", "/tmp/c.heic"]), at: now))
        let mixed = insertedID(try await store.ingest(files(["/tmp/d.png", "/tmp/e.pdf"]), at: now))
        let document = insertedID(try await store.ingest(files(["/tmp/f.txt"]), at: now))
        let picture = insertedID(try await store.ingest(.init(payload: .init([.init([.init(SupportedType.png, Data([1, 2, 3]))])])), at: now))
        #expect(Set(try await store.search(.init(kind: .image)).items.map(\.id)) == [single, several, picture])
        #expect(Set(try await store.search(.init(kind: .file)).items.map(\.id)) == [single, several, mixed, document])
    }
}
