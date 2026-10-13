// 所有历史访问在 actor 内串行且事务内没有 await，by AI.Coding。
import Foundation

let protectedSQL = "isFavorite=1 OR EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id)"
let ordinarySQL = "isFavorite=0 AND NOT EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id)"
func retentionCutoff(settings: SettingsSnapshot, at: Instant) -> Int64? {
    settings.retentionDays == 0 ? nil : at - Int64(settings.retentionDays) * dayMS
}

public actor HistoryStore: HistoryRepository {
    private struct SearchCandidateCache {
        var literal: String
        var filterSignature: String
        var revision: Int64
        var ids: [ClipID]?
    }
    private struct SearchExecution {
        var page: SearchPage
        var candidateIDs: [ClipID]?
        var indexIsComplete: Bool
    }
    private struct SearchContextKey: Hashable {
        var id: ClipID
        var literal: String
    }
    let strategy: CommitStrategy
    let databaseURL: URL
    let clock: any ClipClock
    let extractor: @Sendable (Representation) -> String?
    var listeners: [UUID: AsyncStream<HistoryEvent>.Continuation] = [:]
    var previews: [UUID: ChangePreview] = [:]
    var unavailable = false
    // 仅缓存有限数量的字符统计，不保留正文；记录ID／指纹和可见性仍每次复查。
    private var characterCounts: [ClipID: (hash: String, count: Int)] = [:]
    private var searchCandidateCache: SearchCandidateCache?
    private var searchContextRevision: Int64?
    private var searchContexts: [SearchContextKey: String] = [:]
    private var noMissingTextContentRevision: Int64?
    #if DEBUG
    private(set) var narrowedSearchCount = 0
    #endif
    /// 高版本检查先于 pragma、恢复与任何写操作。
    public init(location: URL, clock: any ClipClock = SystemClock(), faults: any StorageFaultInjector = NoStorageFault(), initialSettings: SettingsSnapshot = .init(), extractor: @escaping @Sendable (Representation) -> String? = BasicTextDecoder.extract) throws {
        self.clock = clock; self.extractor = extractor
        let strategy = try CommitStrategy(root: location, faults: faults)
        if FileManager.default.fileExists(atPath: strategy.databaseURL.path) {
            // 读写打开让SQLite回滚崩溃遗留的热日志；只读取版本，高版本库不被修改。
            let db = try SQLiteConnection(strategy.databaseURL)
            var version = try db.scalarInt("PRAGMA user_version")
            // 唯一受支持的旧版本：先在存储目录外写一致性备份，再原地无损升级；其他版本仍拒绝，by AI.Coding。
            if version == 3 {
                do {
                    let backups = location.appendingPathComponent("Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                    let backup = backups.appendingPathComponent("history-v3-\(clock.now()).sqlite")
                    if !FileManager.default.fileExists(atPath: backup.path) { try db.run("VACUUM INTO ?", [.text(backup.path)]) }
                    try Schema.upgradeFromV3(db)
                } catch { try? db.close(); throw StoreError.incompatibleSchema }
                version = try db.scalarInt("PRAGMA user_version")
            }
            guard version == Schema.version else { try db.close(); throw StoreError.incompatibleSchema }
            guard try db.scalarText("PRAGMA quick_check") == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError.corruptPayload }
            try db.close()
        } else { try strategy.initialize { try Schema.create($0, settings: initialSettings) } }
        self.strategy = strategy; databaseURL = strategy.databaseURL
    }
    /// 读取不可用状态不重放已提交写入。
    private func requireAvailable() throws { if unavailable { throw StoreError.postCommitUnavailable } }
    /// 返回当前持久配置。
    public func settings() throws -> SettingsSnapshot {
        try requireAvailable(); return try strategy.read { try Schema.readSettings($0) }
    }
    /// 名称只更新轻量元数据，原始表示与采集策略版本保持不变，by AI.Coding。
    public func renameClip(id: ClipID, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard name.utf8.count <= 1024, !name.contains(where: { $0.isNewline }), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.invalidSettings }
        let settings = try settings()
        let current = try metadata(id: id, at: clock.now())
        let next = name.isEmpty ? nil : name
        guard current.summary.title != next else { return }
        // 名称是记录行的列：可检索、随删除级联，不再重写整份设置，by AI.Coding。
        // 不允许为名称淘汰历史，容量拒绝与提交失败保留原名。
        try mutate(quota: settings.quotaBytes, growth: 8192 + Int64(name.utf8.count) * 6) { db in
            try db.run("UPDATE clips SET title=?,normalizedTitle=? WHERE id=?", [next.map(SQLValue.text) ?? .null, next.map { .text(SearchNormalizer.normalize($0)) } ?? .null, .text(id)])
        }
    }
    /// 分类名称去空白、NFC规范化与ASCII大小写去重，参数始终绑定。
    private func categoryName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...64).contains(name.count), !name.contains(where: { $0.isNewline }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CategoryError.invalidName }
        return name
    }
    /// 持久分类列表不与历史载荷混存；顺序按创建时间稳定排列。
    public func categories() throws -> [ClipCategory] {
        try requireAvailable()
        return try strategy.read { db in
            try db.rows("SELECT * FROM categories ORDER BY position,id").map { .init(id: $0.text("id"), name: $0.text("name"), colorHex: $0.text("colorHex"), position: Int($0.int("position"))) }
        }
    }
    /// 新建和重命名沿用候选提交与空间计量，失败不会先删除旧历史。
    public func createCategory(name value: String, colorHex: String) throws -> ClipCategory {
        guard colorHex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw StoreError.invalidSettings }
        let name = try categoryName(value), normalized = SearchNormalizer.normalize(name)
        let settings = try settings(), id = UUID().uuidString, at = clock.now()
        try mutate(quota: settings.quotaBytes, growth: 16 * 1024) { db in
            guard try db.scalarInt("SELECT COUNT(*) FROM categories WHERE normalizedName=?", [.text(normalized)]) == 0 else { throw CategoryError.duplicateName }
            try db.run("INSERT INTO categories VALUES(?,?,?,?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM categories))", [.text(id), .text(name), .text(normalized), .integer(at), .text(colorHex)])
        }
        return .init(id: id, name: name, colorHex: colorHex)
    }
    /// 重命名只改名称，不更换ID，因此原归属及当前筛选保持。
    public func renameCategory(id: String, name value: String, colorHex: String) throws {
        guard colorHex.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw StoreError.invalidSettings }
        let name = try categoryName(value), normalized = SearchNormalizer.normalize(name)
        let settings = try settings()
        try mutate(quota: settings.quotaBytes, growth: 8192) { db in
            guard try db.scalarInt("SELECT COUNT(*) FROM categories WHERE id=?", [.text(id)]) == 1 else { throw CategoryError.notFound }
            guard try db.scalarInt("SELECT COUNT(*) FROM categories WHERE normalizedName=? AND id<>?", [.text(normalized), .text(id)]) == 0 else { throw CategoryError.duplicateName }
            try db.run("UPDATE categories SET name=?,normalizedName=?,colorHex=? WHERE id=?", [.text(name), .text(normalized), .text(colorHex), .text(id)])
        }
    }
    /// 版本随每次持久变更递增。
    private func revision(_ db: SQLiteConnection) throws -> Int64 { try db.scalarInt("SELECT storeRevision FROM store_meta WHERE singletonID=1") }
    /// 可见性先应用期限，不能靠异步清理决定是否允许访问。
    private func visible(_ row: [String: SQLValue], at: Instant, settings: SettingsSnapshot) -> Bool {
        if row.int("isProtected") == 1 { return true }
        guard let cutoff = retentionCutoff(settings: settings, at: at) else { return true }
        return row.int("lastCopiedAtMs") > cutoff
    }
    /// 临时触发器捕获所有级联删除，只查本次失去引用的digest，by AI.Coding。
    private func trackBlobRemovals(_ db: SQLiteConnection) throws {
        try db.exec("CREATE TEMP TABLE removed_blob_refs(digest TEXT PRIMARY KEY); CREATE TEMP TRIGGER track_removed_blob_refs AFTER DELETE ON main.representations BEGIN INSERT OR IGNORE INTO removed_blob_refs VALUES(old.blobDigest); END;")
    }
    /// 保留旧接口；没有表示等价性的证明时，不改写历史图片、内容身份或BLOB。
    @discardableResult public func compactRedundantImages() throws -> Int {
        try requireAvailable()
        return 0
    }
    /// 共享BLOB只有最后引用消失才删除，不扫描未变更记录；名称随记录行级联删除。
    private func garbageCollect(_ db: SQLiteConnection) throws {
        try db.exec("DELETE FROM blobs WHERE digest IS NULL; DELETE FROM blobs WHERE digest IN (SELECT digest FROM removed_blob_refs) AND NOT EXISTS(SELECT 1 FROM representations WHERE blobDigest=blobs.digest); DELETE FROM removed_blob_refs")
    }
    /// 共用候选配额算法，预览与实际执行不能采用不同淘汰规则。
    private func fitCandidate(_ db: SQLiteConnection, pending: Int64, quota: Int64, protectedID: ClipID?, allowOverQuota: Bool) throws {
        // 只丢可重建缩略图；存活记录的检索文字始终保留，避免永久全文退化。
        // 处于提交事务内，以非空闲页估算提交截断后的占用，by AI.Coding。
        if try CommitStrategy.pageBytes(db) + pending > quota { try db.exec("DELETE FROM thumbnails") }
        while try CommitStrategy.pageBytes(db) + pending > quota {
            let candidate = try db.scalarText("SELECT id FROM clips WHERE \(ordinarySQL) AND id<>? ORDER BY lastCopiedAtMs,firstCopiedAtMs,id LIMIT 1", [.text(protectedID ?? "")])
            if candidate.isEmpty {
                if allowOverQuota { break }
                throw StoreError.quotaExceeded
            }
            let digests = try db.rows("SELECT DISTINCT blobDigest FROM representations WHERE clipID=?", [.text(candidate)]).map { $0.text("blobDigest") }
            try db.run("DELETE FROM clips WHERE id=?", [.text(candidate)])
            for digest in digests {
                try db.run("DELETE FROM blobs WHERE digest=? AND NOT EXISTS(SELECT 1 FROM representations WHERE blobDigest=blobs.digest)", [.text(digest)])
            }
        }
    }
    /// 单一候选变更入口；淘汰只发生于候选，对外发布仍是一个原子点。
    private func mutate(operation: String = UUID().uuidString, quota: Int64, allowOverQuota: Bool = false, growth: Int64 = 0, trim: Bool = false, protectedID: ClipID? = nil, _ body: (SQLiteConnection) throws -> Void) throws {
        try requireAvailable()
        let started = ContinuousClock.now
        let timing = (try? settings().timingEnabled) == true
        defer { if timing { StageTiming.record("storage_commit", since: started, count: 1) } }
        let textIndexWasComplete = noMissingTextContentRevision != nil
        do {
            try strategy.commit(quota: quota, allowOverQuota: allowOverQuota, estimatedGrowth: growth, finalize: { db, pending in
                if trim {
                    try self.fitCandidate(db, pending: pending, quota: quota, protectedID: protectedID, allowOverQuota: allowOverQuota)
                }
            }) { db in
                try trackBlobRemovals(db)
                try body(db)
                try garbageCollect(db)
                try db.run("UPDATE store_meta SET storeRevision=storeRevision+1,lastOperationID=? WHERE singletonID=1", [.text(operation)])
            }
        } catch StoreError.postCommitUnavailable {
            unavailable = true; publish(.unavailable(.postCommitUnavailable)); throw StoreError.postCommitUnavailable
        }
        let revision = try strategy.read { try self.revision($0) }
        if textIndexWasComplete { noMissingTextContentRevision = revision }
        // 删除后立即释放内存派生正文，不能等下一次访问才回收。
        let cachedIDs = Set(thumbnailOrder).union(characterCounts.keys)
        if !cachedIDs.isEmpty {
            let parameters = cachedIDs.map(SQLValue.text), placeholders = cachedIDs.map { _ in "?" }.joined(separator: ",")
            let liveIDs = try strategy.read { Set(try $0.rows("SELECT id FROM clips WHERE id IN(" + placeholders + ")", parameters).map { $0.text("id") }) }
            for id in thumbnailOrder where !liveIDs.contains(id) { thumbnailBytes -= thumbnailCache.removeValue(forKey: id)?.count ?? 0 }
            thumbnailOrder.removeAll { !liveIDs.contains($0) }
            characterCounts = characterCounts.filter { liveIDs.contains($0.key) }
        }
        publish(.changed(revision))
    }
    /// 入库前再复查持久化策略；敏感内容从未进入正文、预览或索引。
    public func ingest(_ snapshot: ClipboardSnapshot, at: Instant) throws -> IngestResult {
        let settings = try settings()
        if let rejection = settings.rejection(source: snapshot.source, types: snapshot.payload.items.map(\.declaredTypes)) { return .skipped(rejection) }
        guard snapshot.policyRevision == settings.revision else { throw StoreError.policyChanged }
        // 身份与容量按全部原始表示计算；超限整体拒绝，不能删减表示后入库。
        let payload = snapshot.payload
        guard !payload.items.isEmpty, payload.items.count <= 32, payload.byteCount <= 50 * MiB else { return .skipped(.tooLarge) }
        for item in payload.items {
            let types = item.representations.map(\.type)
            guard !types.isEmpty, types.count == Set(types).count, types.allSatisfy({ SupportedType.all.contains($0) }) else { return .skipped(.unsupported) }
            // 无效引用和文件/非文件混合快照整体拒绝，不能仅保存其中一部分。
            if types.contains(SupportedType.fileURL), item.fileURL == nil { return .skipped(.unsupported) }
            if let url = item.representations.first(where: { $0.type == SupportedType.url }),
               let text = String(data: url.data, encoding: .utf8), URL(string: text)?.isFileURL == true,
               item.fileURL == nil { return .skipped(.unsupported) }
        }
        if payload.hasFileReferences, payload.fileURLs == nil { return .skipped(.unsupported) }
        let hash = payload.fingerprint
        let existing = try strategy.read { db -> [String: SQLValue]? in
            guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE contentHash=?", [.text(hash)]).first,
                  visible(row, at: at, settings: settings) else { return nil }
            guard try readPayload(db, id: row.text("id")).canonicalData == payload.canonicalData else { throw StoreError.corruptPayload }
            return row
        }
        let id = existing?.text("id") ?? UUID().uuidString
        // 提交后不可用时 caller 不可重放；同 operationID 再调用不增加次数。
        if let existing, try strategy.read({ try $0.scalarText("SELECT lastOperationID FROM store_meta") }) == snapshot.captureID {
            return .deduplicated(existing.text("id"))
        }
        try mutate(operation: snapshot.captureID, quota: settings.quotaBytes, growth: payload.byteCount + Int64(payload.items.count) * 8192 + 64 * 1024, trim: true, protectedID: id) { db in
            if existing != nil {
                try db.run("UPDATE clips SET lastCopiedAtMs=?,copyCount=copyCount+1,sourceBundleID=?,sourceName=?,sourceBasis=? WHERE id=?", [
                    .integer(at), snapshot.source.bundleID.map(SQLValue.text) ?? .null, .text(snapshot.source.name), .text(snapshot.source.basis), .text(id)])
                // 有效用户再次复制在每个归属分类置前；分类排序不能遮住最新复制，by AI.Coding。
                for row in try db.rows("SELECT categoryID FROM clip_categories WHERE clipID=?", [.text(id)]) {
                    try prependCategoryItems([id], categoryID: row.text("categoryID"), db: db)
                }
                if let thumbnail = snapshot.thumbnail, thumbnail.count <= 16 * MiB {
                    try db.run("INSERT OR IGNORE INTO thumbnails VALUES(?,?,?,?)", [.text(id), .integer(0), .blob(thumbnail), .integer(Int64(thumbnail.count))])
                }
            } else {
                // 过期相同内容以新ID保存，不能复活已过期记录。
                try db.run("DELETE FROM clips WHERE contentHash=?", [.text(hash)])
                let text = payload.items.compactMap { extractedText($0) }.joined(separator: "\n")
                try db.run("INSERT INTO clips(id,contentHash,firstCopiedAtMs,lastCopiedAtMs,copyCount,kind,isFavorite,sourceBundleID,sourceName,sourceBasis,previewText) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [.text(id), .text(hash), .integer(at), .integer(at), .integer(1),
                    .text(payload.kind.rawValue), .integer(0), snapshot.source.bundleID.map(SQLValue.text) ?? .null,
                    .text(snapshot.source.name), .text(snapshot.source.basis), .text(String(text.prefix(180)))])
                for (index, item) in payload.items.enumerated() {
                    let declared = String(decoding: try JSONEncoder().encode(item.declaredTypes), as: UTF8.self)
                    try db.run("INSERT INTO items VALUES(?,?,?)", [.text(id), .integer(Int64(index)), .text(declared)])
                    for representation in item.representations {
                        let digest = ContentFingerprint.hash(representation.data)
                        let existingBlob = try db.rows("SELECT payload FROM blobs WHERE digest=?", [.text(digest)]).first
                        if let existingBlob { guard existingBlob.data("payload") == representation.data else { throw StoreError.corruptPayload } }
                        else { try db.run("INSERT INTO blobs VALUES(?,?,?)", [.text(digest), .integer(Int64(representation.data.count)), .blob(representation.data)]) }
                        try db.run("INSERT INTO representations VALUES(?,?,?,?)", [.text(id), .integer(Int64(index)), .text(representation.type), .text(digest)])
                    }
                    if let text = extractedText(item) {
                        try db.run("INSERT INTO text_content VALUES(?,?,?,?)", [.text(id), .integer(Int64(index)), .text(text.utf8.count > MiB && item.representations.contains(where: { $0.type == SupportedType.string }) ? "" : text), .text(SearchNormalizer.normalize(text))])
                    }
                }
                // 采集阶段后台生成的缩略图随记录同一事务落库，重启与滚动不再重读原图，by AI.Coding。
                if let thumbnail = snapshot.thumbnail, thumbnail.count <= 16 * MiB {
                    try db.run("INSERT INTO thumbnails VALUES(?,?,?,?)", [.text(id), .integer(0), .blob(thumbnail), .integer(Int64(thumbnail.count))])
                }
            }
        }
        return existing == nil ? .inserted(id) : .deduplicated(id)
    }
    /// 通过本应用复制/粘贴的记录视为再次使用：置前并计数，与用户重新复制同一内容一致，by AI.Coding。
    public func touch(ids: [ClipID], at: Instant) throws {
        let settings = try settings()
        try mutate(quota: settings.quotaBytes, allowOverQuota: true, growth: 8192) { db in
            var seen = Set<ClipID>()
            var categoryItems: [String: [ClipID]] = [:]
            for id in ids where seen.insert(id).inserted {
                try db.run("UPDATE clips SET lastCopiedAtMs=?,copyCount=copyCount+1 WHERE id=?", [.integer(at), .text(id)])
                // 按原选择顺序收集，每个分类整批置前，避免Set乱序和逐项置前反转。
                for row in try db.rows("SELECT categoryID FROM clip_categories WHERE clipID=?", [.text(id)]) {
                    categoryItems[row.text("categoryID"), default: []].append(id)
                }
            }
            for (categoryID, orderedIDs) in categoryItems {
                try prependCategoryItems(orderedIDs, categoryID: categoryID, db: db)
            }
        }
    }
    /// 文本优先级固定，原始格式不会因展示摘要损失。
    private func extractedText(_ item: PasteboardItemValue) -> String? {
        for type in [SupportedType.fileURL, SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html] {
            if let representation = item.representations.first(where: { $0.type == type }), let text = extractor(representation) { return text }
        }
        return item.plainText
    }
    /// 原始恢复仅按项目顺序加载；核对类型、字节数和摘要防止静默损坏。
    private func readPayload(_ db: SQLiteConnection, id: ClipID) throws -> ClipboardPayload {
        let items = try db.rows("SELECT * FROM items WHERE clipID=? ORDER BY itemIndex", [.text(id)])
        guard !items.isEmpty, items.count <= 32 else { throw StoreError.corruptPayload }
        var values: [PasteboardItemValue] = []
        for (index, row) in items.enumerated() {
            guard row.int("itemIndex") == Int64(index) else { throw StoreError.corruptPayload }
            let rows = try db.rows("SELECT type,blobDigest,payload,byteCount FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND itemIndex=? ORDER BY type", [.text(id), .integer(Int64(index))])
            guard !rows.isEmpty else { throw StoreError.corruptPayload }
            var reps: [Representation] = []
            for row in rows {
                let data = row.data("payload")
                guard SupportedType.all.contains(row.text("type")), Int64(data.count) == row.int("byteCount"), ContentFingerprint.hash(data) == row.text("blobDigest") else { throw StoreError.corruptPayload }
                reps.append(.init(row.text("type"), data))
            }
            let declared = try JSONDecoder().decode([String].self, from: Data(row.text("declaredTypes").utf8))
            var item = PasteboardItemValue(reps, declaredTypes: declared)
            item.plainText = try db.rows("SELECT plainText FROM text_content WHERE clipID=? AND itemIndex=?", [.text(id), .integer(Int64(index))]).first?.text("plainText").nonEmpty ?? extractedText(item)
            values.append(item)
        }
        let payload = ClipboardPayload(values)
        let storedHash = try db.scalarText("SELECT contentHash FROM clips WHERE id=?", [.text(id)])
        guard payload.fingerprint == storedHash else { throw StoreError.corruptPayload }
        return payload
    }
    /// 同一可见性规则覆盖详情和恢复。
    public func detail(id: ClipID, at: Instant) throws -> ClipDetail {
        try Task.checkCancellation()
        let settings = try settings()
        return try strategy.read { db in
            guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE id=?", [.text(id)]).first,
                  visible(row, at: at, settings: settings) else { throw StoreError.notFound }
            let categoryIDs = Set(try db.rows("SELECT categoryID FROM clip_categories WHERE clipID=?", [.text(id)]).map { $0.text("categoryID") })
            return ClipDetail(summary: summary(row), payload: try readPayload(db, id: id), revision: try self.revision(db), categoryIDs: categoryIDs)
        }
    }
    /// 选择/异步缩略图复查只读索引与摘要，不读取BLOB或计算内容哈希。
    public func metadata(id: ClipID, at: Instant) throws -> ClipMetadata {
        try Task.checkCancellation()
        let settings = try settings()
        return try strategy.read { db in
            guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE id=?", [.text(id)]).first,
                  visible(row, at: at, settings: settings) else { throw StoreError.notFound }
            let categories = Set(try db.rows("SELECT categoryID FROM clip_categories WHERE clipID=?", [.text(id)]).map { $0.text("categoryID") })
            let total = try db.scalarInt("SELECT COUNT(*) FROM items WHERE clipID=?", [.text(id)])
            let textual = try db.scalarInt("SELECT COUNT(DISTINCT itemIndex) FROM representations WHERE clipID=? AND type IN('public.utf8-plain-text','public.url','public.rtf','public.html','public.file-url')", [.text(id)])
            return .init(summary: summary(row), categoryIDs: categories, hasTextRepresentations: total > 0 && total == textual, revision: try self.revision(db))
        }
    }
    /// 接口分离避免列表批量读取图片。
    public func loadPayload(id: ClipID, at: Instant) throws -> ClipboardPayload { try detail(id: id, at: at).payload }
    /// 可见文本卡片按需统计完整文字，不把180字符摘要当全文，不批量读取图片或文件载荷。
    public func textCharacterCount(id: ClipID, at: Instant) throws -> Int? {
        let settings = try settings()
        return try strategy.read { db in
            guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE id=?", [.text(id)]).first,
                  visible(row, at: at, settings: settings) else { throw StoreError.notFound }
            let hash = row.text("contentHash")
            if let cached = characterCounts[id], cached.hash == hash { return cached.count }
            let types = [SupportedType.string, SupportedType.url, SupportedType.rtf, SupportedType.html]
            let placeholders = types.map { _ in "?" }.joined(separator: ",")
            let parameters: [SQLValue] = [.text(id)] + types.map(SQLValue.text)
            let indices = try db.rows("SELECT DISTINCT itemIndex FROM representations WHERE clipID=? AND type IN(" + placeholders + ") ORDER BY itemIndex", parameters)
            guard !indices.isEmpty else { return nil }
            let indexed = try db.rows("SELECT itemIndex,plainText FROM text_content WHERE clipID=? ORDER BY itemIndex", [.text(id)])
            var texts: [String] = []
            for index in indices {
                let itemIndex = index.int("itemIndex")
                if let text = indexed.first(where: { $0.int("itemIndex") == itemIndex }), !text.text("plainText").isEmpty {
                    texts.append(text.text("plainText")); continue
                }
                // 派生索引可能被容量策略回收；只恢复文字表示，绝不读取同项目的图片字节。
                let values = try db.rows("SELECT type,blobDigest,payload,byteCount FROM representations JOIN blobs ON digest=blobDigest WHERE clipID=? AND type IN(" + placeholders + ") AND itemIndex=?", parameters + [.integer(itemIndex)])
                var representations: [Representation] = []
                for value in values {
                    let data = value.data("payload")
                    guard Int64(data.count) == value.int("byteCount"), ContentFingerprint.hash(data) == value.text("blobDigest") else { throw StoreError.corruptPayload }
                    representations.append(.init(value.text("type"), data))
                }
                if let text = extractedText(.init(representations)) { texts.append(text) }
            }
            guard !texts.isEmpty else { return nil }
            let count = texts.joined(separator: "\n").count
            if characterCounts.count >= 128 { characterCounts.removeAll(keepingCapacity: true) }
            characterCounts[id] = (hash, count)
            return count
        }
    }
    /// 摘要只包含轻量元数据；未知来源不沿用旧来源。
    private func summary(_ row: [String: SQLValue], context: String? = nil) -> ClipSummary {
        let bundle = row.text("sourceBundleID")
        return ClipSummary(id: row.text("id"), firstCopiedAt: row.int("firstCopiedAtMs"), lastCopiedAt: row.int("lastCopiedAtMs"),
            copyCount: Int(row.int("copyCount")), kind: ClipKind(rawValue: row.text("kind")) ?? .mixed,
            isFavorite: row.int("isFavorite") == 1, isProtected: row.int("isProtected") == 1, source: .init(bundleID: bundle.isEmpty ? nil : bundle, name: row.text("sourceName"), basis: row.text("sourceBasis")),
            preview: row.text("previewText"), context: context ?? row.text("previewText"), title: row.text("title").nonEmpty)
    }
    /// 全文字面子串；缺索引时从可提取原始表示回退，不能丢长文尾部。
    public func search(_ request: SearchRequest) throws -> SearchPage {
        let literal = SearchNormalizer.normalize(request.literal)
        let currentRevision = try strategy.read { try self.revision($0) }
        var candidates: Set<ClipID>?
        if let cached = searchCandidateCache,
           cached.revision == currentRevision,
           cached.filterSignature == filterSignature(request),
           let ids = cached.ids,
           literal == cached.literal || (literal.count > cached.literal.count && literal.hasPrefix(cached.literal)) {
            candidates = Set(ids)
        }
        #if DEBUG
        if candidates != nil { narrowedSearchCount += 1 }
        #endif
        let result = try searchExecution(request, onlyIDs: candidates, includeMatchContext: true)
        if !literal.isEmpty, request.cursor == nil {
            searchCandidateCache = .init(literal: literal, filterSignature: filterSignature(request), revision: result.page.revision, ids: result.candidateIDs)
        } else if literal.isEmpty, request.cursor == nil {
            searchCandidateCache = nil
        }
        if result.indexIsComplete { noMissingTextContentRevision = result.page.revision }
        return result.page
    }
    /// 刷新前核对浏览锚点是否仍属于查询，删除/筛选移除的ID不能迫使扫描完整历史。
    public func matchingIDs(_ ids: Set<ClipID>, in request: SearchRequest) throws -> (ids: Set<ClipID>, revision: Int64) {
        var matching: Set<ClipID> = []
        let revision = try strategy.read { try self.revision($0) }
        let values = Array(ids)
        for start in stride(from: 0, to: values.count, by: 50) {
            var query = request; query.cursor = nil; query.pageSize = 50
            let page = try searchExecution(query, onlyIDs: Set(values[start..<min(start + 50, values.count)]), includeMatchContext: false).page
            guard page.revision == revision else { throw StoreError.invalidCursor }
            matching.formUnion(page.items.map(\.id))
        }
        return (matching, revision)
    }
    func search(_ request: SearchRequest, onlyIDs: Set<ClipID>?) throws -> SearchPage {
        try searchExecution(request, onlyIDs: onlyIDs, includeMatchContext: true, useContextCache: false).page
    }
    private func filterSignature(_ request: SearchRequest) -> String {
        var filters = request; filters.literal = ""
        return filters.signature
    }
    private func searchExecution(_ request: SearchRequest, onlyIDs: Set<ClipID>?, includeMatchContext: Bool, useContextCache: Bool = true) throws -> SearchExecution {
        let settings = try settings(); let at = clock.now()
        let knownCompleteRevision = noMissingTextContentRevision
        return try strategy.read { db in
            let revision = try self.revision(db)
            if let cursor = request.cursor, cursor.revision != revision || cursor.signature != request.signature { throw StoreError.invalidCursor }
            if searchContextRevision != revision {
                searchContextRevision = revision; searchContexts.removeAll(keepingCapacity: true)
            }
            var (condition, filters, order) = searchCondition(request, settings: settings, at: at)
            if let onlyIDs {
                let ids = onlyIDs.sorted()
                condition += " AND id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ")"
                filters += ids.map { .text($0) }
            }
            let needle = SearchNormalizer.normalize(request.literal)
            let offset = request.cursor?.offset ?? 0; let size = min(50, max(1, request.pageSize))
            guard offset >= 0 else { throw StoreError.invalidCursor }
            if needle.isEmpty {
                // 多取一行判断下一页，普通浏览不再为每页额外统计全库，顺序/版本身份不变，by AI.Coding。
                let rows = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE " + condition + " ORDER BY " + order + " LIMIT ? OFFSET ?", filters + (request.categoryIDs.count == 1 ? [.text(request.categoryIDs.first!)] : []) + [.integer(Int64(size + 1)), .integer(Int64(offset))])
                if rows.isEmpty && offset > 0 {
                    guard offset <= Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE " + condition, filters)) else { throw StoreError.invalidCursor }
                }
                let page = SearchPage(queryID: request.queryID, revision: revision, items: rows.prefix(size).map { summary($0) }, next: rows.count > size ? .init(revision: revision, offset: offset + size, signature: request.signature) : nil)
                return .init(page: page, candidateIDs: nil, indexIsComplete: knownCompleteRevision == revision)
            }
            // 按SQLite页缓存扫描有界结果，不在Swift中常驻全部正文/规范化副本。
            // BLOB instr保持NUL及UTF-8字节字面语义，不使用LIKE/FTS通配规则。
            let indexIsComplete: Bool
            let allMissing: [[String: SQLValue]]
            if knownCompleteRevision == revision || onlyIDs?.isEmpty == true {
                indexIsComplete = knownCompleteRevision == revision
                allMissing = []
            } else {
                allMissing = try db.rows("SELECT DISTINCT r.clipID FROM representations r LEFT JOIN text_content t ON t.clipID=r.clipID AND t.itemIndex=r.itemIndex WHERE t.clipID IS NULL AND r.type IN('public.utf8-plain-text','public.url','public.rtf','public.html','public.file-url')")
                indexIsComplete = allMissing.isEmpty
            }
            let missing = onlyIDs.map { ids in allMissing.filter { ids.contains($0.text("clipID")) } } ?? allMissing
            // 旧库缺失索引先在只读连接的临时表补齐，原始载荷仍是最终依据。
            if !missing.isEmpty {
                try db.exec("CREATE TEMP TABLE search_repair(clipID TEXT,itemIndex INTEGER,plainText TEXT,normalizedText TEXT)")
                for row in missing {
                    let payload = try readPayload(db, id: row.text("clipID"))
                    for (index, item) in payload.items.enumerated() {
                        guard try db.scalarInt("SELECT COUNT(*) FROM text_content WHERE clipID=? AND itemIndex=?", [.text(row.text("clipID")), .integer(Int64(index))]) == 0 else { continue }
                        let text = extractedText(item) ?? ""
                        try db.run("INSERT INTO search_repair VALUES(?,?,?,?)", [.text(row.text("clipID")), .integer(Int64(index)), .text(text), .text(SearchNormalizer.normalize(text))])
                    }
                }
            }
            let indexed = missing.isEmpty ? "text_content" : "(SELECT * FROM text_content UNION ALL SELECT * FROM search_repair)"
            let sql = """
            WITH matches AS MATERIALIZED (
                SELECT clips.*, (\(protectedSQL)) AS isProtected,
                -- 自定义名称命中与正文开头同级；正文排名规则不变，by AI.Coding。
                MIN(CASE WHEN instr(normalizedTitle,?1)>0 THEN 1 ELSE 4 END, clip_literal_rank(
                    (SELECT CAST(group_concat(normalizedText,char(10)) AS BLOB)
                     FROM (SELECT normalizedText FROM \(indexed) WHERE clipID=clips.id ORDER BY itemIndex)),
                    CAST(?1 AS BLOB),sourceName)) AS matchRank
                FROM clips WHERE \(condition)
            ), matching AS MATERIALIZED (
                SELECT * FROM matches WHERE matchRank<4
            ), candidate_ids AS (
                SELECT json_group_array(id) AS candidateIDs FROM (
                    SELECT id FROM matching ORDER BY matchRank,lastCopiedAtMs DESC,id LIMIT 5001
                )
            ), page AS (
                SELECT * FROM matching ORDER BY matchRank,lastCopiedAtMs DESC,id LIMIT ? OFFSET ?
            ) SELECT page.*,candidate_ids.candidateIDs FROM candidate_ids LEFT JOIN page ON true
            """
            let rows = try db.rows(sql, [.text(needle)] + filters + [.integer(Int64(size + 1)), .integer(Int64(offset))])
            let candidateJSON = rows.first?.text("candidateIDs") ?? "[]"
            let decodedCandidates = try JSONDecoder().decode([ClipID].self, from: Data(candidateJSON.utf8))
            let candidateIDs = decodedCandidates.count > 5000 ? nil : decodedCandidates
            let pageRows = rows.filter { !$0.text("id").isEmpty }
            let page = try pageRows.prefix(size).map { row -> ClipSummary in
                if !includeMatchContext { return summary(row) }
                let key = SearchContextKey(id: row.text("id"), literal: needle)
                if useContextCache, let cached = searchContexts[key] { return summary(row, context:cached) }
                let context: String
                if row.int("matchRank") == 3 { context = row.text("sourceName") }
                else {
                    let texts = try db.rows("SELECT plainText,normalizedText FROM \(indexed) WHERE clipID=? ORDER BY itemIndex", [.text(row.text("id"))])
                    if texts.contains(where: { $0.text("plainText").isEmpty }) {
                        let body = try readPayload(db, id: row.text("id")).items.compactMap(\.plainText).joined(separator: "\n")
                        context = SearchNormalizer.context(body, literal: request.literal)
                    } else {
                        context = SearchNormalizer.context(texts.map { $0.text("plainText") }.joined(separator: "\n"),
                            normalized: texts.map { $0.text("normalizedText") }.joined(separator: "\n"), literal: request.literal)
                    }
                }
                // 仅缓存有界命中片段；修订变更清空，筛选、可见性及排序仍每次查询，by AI.Coding。
                if useContextCache, searchContexts.count < 256, context.utf8.count <= 4096 { searchContexts[key] = context }
                return summary(row, context:context)
            }
            let resultPage = SearchPage(queryID: request.queryID, revision: revision, items: page,
                next: pageRows.count > size ? .init(revision: revision, offset: offset + size, signature: request.signature) : nil)
            return .init(page: resultPage, candidateIDs: candidateIDs, indexIsComplete: indexIsComplete)
        }
    }
    /// 旧库曾回收的全文索引以最多200条候选批次补齐；失败不淘汰任何历史。
    public func rebuildSearchIndex(limit: Int = 200) throws -> Int {
        let missing = try strategy.read { db in
            try db.rows("SELECT DISTINCT r.clipID FROM representations r LEFT JOIN text_content t ON t.clipID=r.clipID AND t.itemIndex=r.itemIndex WHERE t.clipID IS NULL AND r.type IN('public.utf8-plain-text','public.url','public.rtf','public.html','public.file-url') LIMIT ?", [.integer(Int64(min(200, max(1, limit))))]).map { $0.text("clipID") }
        }
        guard !missing.isEmpty else { return 0 }
        let settings = try settings()
        try mutate(quota: settings.quotaBytes) { db in
            for id in missing {
                let payload = try readPayload(db, id: id)
                for (index, item) in payload.items.enumerated() {
                    guard item.representations.contains(where: { [SupportedType.string, SupportedType.url, SupportedType.fileURL, SupportedType.rtf, SupportedType.html].contains($0.type) }),
                          try db.scalarInt("SELECT COUNT(*) FROM text_content WHERE clipID=? AND itemIndex=?", [.text(id), .integer(Int64(index))]) == 0 else { continue }
                    let text = extractedText(item) ?? ""
                    let compact = text.utf8.count > MiB && item.representations.contains(where: { $0.type == SupportedType.string })
                    try db.run("INSERT INTO text_content VALUES(?,?,?,?)", [.text(id), .integer(Int64(index)), .text(compact ? "" : text), .text(SearchNormalizer.normalize(text))])
                }
            }
        }
        return missing.count
    }
    /// 变更预览带数据库/设置版本，确认过期必须重新预览。
    public func preview(_ change: HistoryChange) throws -> ChangePreview {
        let settings = try settings(); let at = clock.now()
        var message = "删除后立即移除；30秒内、合计50MiB以内可在本会话撤销。超出预算不可撤销。"
        var confirmation = true; var count = 0
        let revision = try strategy.read { db -> Int64 in
            switch change {
            case .favorite(let id, let value):
                guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE id=?", [.text(id)]).first,
                      visible(row, at: at, settings: settings) else { throw StoreError.notFound }
                let expired = retentionCutoff(settings: settings, at: at).map { row.int("lastCopiedAtMs") <= $0 } ?? false
                let otherProtection = try db.scalarInt("SELECT COUNT(*) FROM clip_categories WHERE clipID=?", [.text(id)]) > 0
                confirmation = !value && expired && !otherProtection; count = confirmation ? 1 : 0
                message = confirmation ? "取消收藏后将按保留规则删除" : "更改收藏"
            case .favorites(let ids, let value):
                count = try expiredUnprotectedCount(db, ids: ids, removingCategory: nil, removingFavorite: !value, settings: settings, at: at)
                confirmation = !value && count > 0; message = "批量更改收藏；失去最后保护的到期记录将删除"
            case .category(let ids, let category, let included):
                guard try db.scalarInt("SELECT COUNT(*) FROM categories WHERE id=?", [.text(category)]) == 1 else { throw CategoryError.notFound }
                count = included ? 0 : try expiredUnprotectedCount(db, ids: ids, removingCategory: category, removingFavorite: false, settings: settings, at: at)
                confirmation = !included && count > 0; message = "移除分类归属；失去最后保护的到期记录将删除"
            case .deleteCategory(let category):
                let ids = try db.rows("SELECT clipID FROM clip_categories WHERE categoryID=?", [.text(category)]).map { $0.text("clipID") }
                count = try expiredUnprotectedCount(db, ids: ids, removingCategory: category, removingFavorite: false, settings: settings, at: at)
                confirmation = true; message = "删除分类，保留有效记录；失去最后保护的到期记录将删除"
            case .delete(let ids):
                confirmation = false
                for id in Set(ids) { count += Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=?", [.text(id)])) }
            case .clearOrdinary: count = Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE \(ordinarySQL)"))
            case .retention(let days):
                guard (0...365).contains(days) else { throw StoreError.invalidSettings }
                var proposed = settings; proposed.retentionDays = days
                if let cutoff = retentionCutoff(settings: proposed, at: at) {
                    count = Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE \(ordinarySQL) AND lastCopiedAtMs<=?", [.integer(cutoff)]))
                } else { count = 0 }
                confirmation = days != 0 && (settings.retentionDays == 0 || days < settings.retentionDays); message = "更改保留期限；到期普通历史将删除，收藏与分类保护保留。"
            case .quota(let bytes):
                guard (100 * MiB...4096 * MiB).contains(bytes) else { throw StoreError.invalidSettings }
                count = Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE \(ordinarySQL)"))
                confirmation = bytes < settings.quotaBytes; message = "调整容量，必要时从最早复制的普通历史开始清理；收藏与分类保护保留。"
            }
            return try self.revision(db)
        }
        // 用同一个候选配额算法做只读结果预演；不替换原库、不发布事件。
        var estimated: Int64 = 0
        if case .quota(let bytes) = change, bytes < settings.quotaBytes {
            let before = try usage().measuredTotal
            let oldCount = try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM clips") }
            try strategy.commit(quota: bytes, allowOverQuota: true, dryRun: true, finalize: { db, pending in
                try self.fitCandidate(db, pending: pending, quota: bytes, protectedID: nil, allowOverQuota: true)
            }) { db in
                try trackBlobRemovals(db)
                var lowered = settings; lowered.quotaBytes = bytes; lowered.revision += 1
                try Schema.writeSettings(db, lowered)
                try self.removeExpired(db, settings: settings, at: at)
                try garbageCollect(db)
            }
            count = Int(oldCount - strategy.lastCandidateClipCount)
            estimated = max(0, before - strategy.lastCandidateBytes - (try CommitStrategy.bytes(strategy.staging)))
        }
        let preview = ChangePreview(token: UUID(), operation: change, storeRevision: revision, settingsRevision: settings.revision,
            affectedCount: count, estimatedReclaimBytes: estimated, requiresConfirmation: confirmation, message: message)
        if previews.count >= 64 { previews.removeAll() }
        previews[preview.token] = preview
        return preview
    }
    /// 用户取消不会调用 apply；token 单次且重新校验版本。
    public func apply(_ token: UUID) throws -> ChangeResult {
        guard let preview = previews.removeValue(forKey: token) else { throw StoreError.stalePreview }
        var settings = try settings()
        let current = try strategy.read { try self.revision($0) }
        guard preview.storeRevision == current, preview.settingsRevision == settings.revision else { throw StoreError.stalePreview }
        let before = try usage().measuredTotal; let oldCount = try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM clips") }; let at = clock.now()
        if case .quota(let bytes) = preview.operation { settings.quotaBytes = bytes }
        if case .retention(let days) = preview.operation { settings.retentionDays = days }
        let undoCandidate = try makeUndo(preview.operation)
        let trim: Bool = { if case .quota = preview.operation { true } else { false } }()
        // 下调容量的预演与提交都保留保护内容；超额时停止新增，by AI.Coding。
        try mutate(quota: settings.quotaBytes, allowOverQuota: true, trim: trim) { db in
            switch preview.operation {
            case .favorite(let id, let value):
                try db.run("UPDATE clips SET isFavorite=? WHERE id=?", [.integer(value ? 1 : 0), .text(id)])
                if !value, let cutoff = retentionCutoff(settings: settings, at: at) {
                    try db.run("DELETE FROM clips WHERE id=? AND \(ordinarySQL) AND lastCopiedAtMs<=?", [.text(id), .integer(cutoff)])
                }
            case .favorites(let ids, let value):
                for id in Set(ids) { try db.run("UPDATE clips SET isFavorite=? WHERE id=?", [.integer(value ? 1 : 0), .text(id)]) }
                try removeExpired(db, settings: settings, at: at)
            case .category(let ids, let category, let included):
                // 多选拖入保持原有从左到右顺序，不能经Set迭代随机打乱，by AI.Coding。
                var seen: Set<ClipID> = []
                let ordered = ids.filter { seen.insert($0).inserted }
                for id in ordered {
                    guard let row = try db.rows("SELECT *, (\(protectedSQL)) AS isProtected FROM clips WHERE id=?", [.text(id)]).first, visible(row, at: at, settings: settings) else { throw StoreError.notFound }
                    if !included { try db.run("DELETE FROM clip_categories WHERE categoryID=? AND clipID=?", [.text(category), .text(id)]) }
                }
                if included { try prependCategoryItems(ordered, categoryID: category, db: db) }
                try removeExpired(db, settings: settings, at: at)
            case .deleteCategory(let category):
                try db.run("DELETE FROM categories WHERE id=?", [.text(category)])
                try removeExpired(db, settings: settings, at: at)
            case .delete(let ids): for id in Set(ids) { try db.run("DELETE FROM clips WHERE id=?", [.text(id)]) }
            case .clearOrdinary: try db.exec("DELETE FROM clips WHERE \(ordinarySQL)")
            case .retention, .quota:
                settings.revision += 1; try Schema.writeSettings(db, settings)
                try removeExpired(db, settings: settings, at: at)
            }
        }
        if case .delete = preview.operation {
            undoExpiry?.cancel(); undoPacket = undoCandidate
            if let undoCandidate { undoExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.clearUndo(expires: undoCandidate.expires)
            } }
        }
        let newCount = try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM clips") }
        return ChangeResult(removed: Int(oldCount - newCount), reclaimedBytes: max(0, before - (try usage().measuredTotal)), revision: try strategy.read { try self.revision($0) })
    }
    /// 定时到期清理独立于保存失败，不会删除收藏。
    public func expire(at: Instant) throws -> ChangeResult {
        let settings = try settings()
        guard let cutoff = retentionCutoff(settings: settings, at: at) else {
            return .init(removed: 0, reclaimedBytes: 0, revision: try strategy.read { try self.revision($0) })
        }
        let count = try strategy.read { try $0.scalarInt("SELECT COUNT(*) FROM clips WHERE \(ordinarySQL) AND lastCopiedAtMs<=?", [.integer(cutoff)]) }
        if count == 0 { return .init(removed: 0, reclaimedBytes: 0, revision: try strategy.read { try self.revision($0) }) }
        let before = try usage().measuredTotal
        try mutate(quota: settings.quotaBytes, allowOverQuota: true) { db in
            try db.run("DELETE FROM clips WHERE \(ordinarySQL) AND lastCopiedAtMs<=?", [.integer(cutoff)])
        }
        return .init(removed: Int(count), reclaimedBytes: max(0, before - (try usage().measuredTotal)), revision: try strategy.read { try self.revision($0) })
    }
    /// 实际文件总量与共享载荷分类，公共页与日志不重复分摊。
    public func usage() throws -> StorageUsage {
        try requireAvailable()
        let pending = try CommitStrategy.bytes(strategy.staging)
        let temporary = try CommitStrategy.bytes(strategy.root.appendingPathComponent("Exports"))
        let total = try CommitStrategy.bytes(strategy.databaseURL.deletingLastPathComponent()) + pending + temporary
        let values = try strategy.read { db -> (Int64, Int64) in
            let favorite = try db.scalarInt("SELECT COALESCE(SUM(byteCount),0) FROM blobs WHERE EXISTS(SELECT 1 FROM representations JOIN clips ON clips.id=representations.clipID WHERE blobDigest=blobs.digest AND (\(protectedSQL)))")
            let all = try db.scalarInt("SELECT COALESCE(SUM(byteCount),0) FROM blobs")
            return (favorite, all - favorite)
        }
        return StorageUsage(measuredTotal: total, favoritePayload: values.0, normalPayload: values.1,
            common: max(0, total - pending - temporary - values.0 - values.1), pending: pending, temporary: temporary)
    }
    /// 实际总量达到上限时在独立候选中移除可释放内容，判断是否真的需要全局暂停。
    public func canCapture() throws -> Bool {
        let settings = try settings(), usage = try usage()
        if usage.measuredTotal < settings.quotaBytes { return true }
        try strategy.commit(quota: settings.quotaBytes, allowOverQuota: true, dryRun: true) { db in
            try trackBlobRemovals(db)
            try db.exec("DELETE FROM clips WHERE \(ordinarySQL); DELETE FROM thumbnails")
            try garbageCollect(db)
        }
        return strategy.lastCandidateBytes + (try CommitStrategy.bytes(strategy.staging)) + (try CommitStrategy.bytes(strategy.root.appendingPathComponent("Exports"))) < settings.quotaBytes
    }
    /// 非破坏性设置也递增版本；容量与期限只能走确认接口。
    public func updateCaptureSettings(_ next: SettingsSnapshot) throws -> SettingsSnapshot {
        try next.validate(); let current = try settings()
        guard next.retentionDays == current.retentionDays, next.quotaBytes == current.quotaBytes, next.revision == current.revision else { throw StoreError.stalePreview }
        var next = next; next.revision += 1
        try mutate(quota: current.quotaBytes, allowOverQuota: true) { try Schema.writeSettings($0, next) }
        publish(.settings(next.revision)); return next
    }
    /// 订阅只传版本与状态，不在日志/事件里泄漏正文。
    public func events() -> AsyncStream<HistoryEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        }
    }
    /// 取消订阅立即释放 continuation。
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    /// 仅持久化提交后发布。
    private func publish(_ event: HistoryEvent) { for listener in listeners.values { listener.yield(event) } }
    /// 启动恢复完成之前协调层不会开始采集；只做快速检查，完整检查交给后台维护，by AI.Coding。
    public func recover() throws -> RecoveryReport {
        let pending = try strategy.recover()
        let db = try SQLiteConnection(strategy.databaseURL)
        guard try db.scalarInt("PRAGMA user_version") == Schema.version,
              try db.scalarText("PRAGMA quick_check") == "ok", try db.rows("PRAGMA foreign_key_check").isEmpty else { throw StoreError.corruptPayload }
        let revision = try self.revision(db); try db.close(); unavailable = false
        return .init(revision: revision, pendingBytes: pending)
    }
    /// 完整页级校验在actor内执行：期间写入排队等待而非因锁超时失败；读取错误抛出，
    /// 只有确认损坏才返回false并进入不可用流程，由维护任务低频调用，by AI.Coding。
    public func integrityCheck() throws -> Bool {
        try requireAvailable()
        let ok = try strategy.read { try $0.scalarText("PRAGMA integrity_check") } == "ok"
        if !ok { unavailable = true; publish(.unavailable(.corruptPayload)) }
        return ok
    }
    private var thumbnailCache: [ClipID: Data] = [:]
    private var thumbnailOrder: [ClipID] = []
    private var thumbnailBytes = 0
    /// 不可变内容按ID缓存至多16MiB派生数据；当前可见性检查阻止删除后重生，by AI.Coding。
    public func cacheThumbnail(id: ClipID, revision expected: Int64, data: Data) throws -> Bool {
        let metadata = try? metadata(id: id, at: clock.now())
        guard metadata != nil, data.count <= 16 * MiB else { return false }
        if let previous = thumbnailCache.removeValue(forKey: id) { thumbnailBytes -= previous.count }
        thumbnailOrder.removeAll { $0 == id }
        while thumbnailBytes + data.count > 16 * MiB || thumbnailOrder.count >= 256, let old = thumbnailOrder.first {
            thumbnailOrder.removeFirst(); thumbnailBytes -= thumbnailCache.removeValue(forKey: old)?.count ?? 0
        }
        thumbnailCache[id] = data; thumbnailOrder.append(id); thumbnailBytes += data.count
        // 旧记录首次生成的缩略图也落库；派生数据不递增版本、不发布事件，超额时只保留内存缓存，by AI.Coding。
        if let quota = try? settings().quotaBytes {
            try? strategy.commit(quota: quota, estimatedGrowth: Int64(data.count)) { db in
                try db.run("INSERT OR IGNORE INTO thumbnails SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM clips WHERE id=?)", [.text(id), .integer(expected), .blob(data), .integer(Int64(data.count)), .text(id)])
            }
        }
        return true
    }
    /// 内存命中也复查可见性；持久旧缓存不会产生新写入。
    public func thumbnail(id: ClipID, at: Instant) throws -> Data? {
        _ = try metadata(id: id, at: at)
        if let cached = thumbnailCache[id] { return cached }
        return try strategy.read { try $0.rows("SELECT encodedImage FROM thumbnails WHERE clipID=?", [.text(id)]).first?.data("encodedImage") }
    }

    private struct UndoPacket {
        let expires: Instant
        let tables: [String: [[String: SQLValue]]]
        let bytes: Int64
    }
    private var undoPacket: UndoPacket?
    private var undoExpiry: Task<Void, Never>?
    /// 分类保护在SQL与内存摘要中一致；永不过期仍遵循物理容量。
    private func removeExpired(_ db: SQLiteConnection, settings: SettingsSnapshot, at: Instant) throws {
        guard let cutoff = retentionCutoff(settings: settings, at: at) else { return }
        try db.run("DELETE FROM clips WHERE \(ordinarySQL) AND lastCopiedAtMs<=?", [.integer(cutoff)])
    }
    /// 最后保护移除前仅计数，供用户确认，不读取正文。
    private func expiredUnprotectedCount(_ db: SQLiteConnection, ids: [ClipID], removingCategory: String?, removingFavorite: Bool, settings: SettingsSnapshot, at: Instant) throws -> Int {
        guard let cutoff = retentionCutoff(settings: settings, at: at) else { return 0 }
        var count = 0
        for id in Set(ids) {
            count += Int(try db.scalarInt("SELECT COUNT(*) FROM clips WHERE id=? AND lastCopiedAtMs<=? AND (?=1 OR isFavorite=0) AND NOT EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id AND categoryID<>?)", [.text(id), .integer(cutoff), .integer(removingFavorite ? 1 : 0), .text(removingCategory ?? "")]))
        }
        return count
    }
    /// 查询参数绑定，日期为本地日历转换的半开区间；单分类使用人工顺序。
    private func searchCondition(_ request: SearchRequest, settings: SettingsSnapshot, at: Instant) -> (String, [SQLValue], String) {
        var clauses = ["(? IS NULL OR (\(protectedSQL)) OR lastCopiedAtMs>?)"]
        let cutoff = retentionCutoff(settings: settings, at: at)
        var values: [SQLValue] = [cutoff.map(SQLValue.integer) ?? .null, cutoff.map(SQLValue.integer) ?? .null]
        if request.favoritesOnly { clauses.append("isFavorite=1") }
        if let kind = request.kind { clauses.append("kind=?"); values.append(.text(kind.rawValue)) }
        if let source = request.sourceBundleID { clauses.append("COALESCE(sourceBundleID,'')=?"); values.append(.text(source)) }
        if let from = request.from { clauses.append("lastCopiedAtMs>=?"); values.append(.integer(from)) }
        if let until = request.until { clauses.append("lastCopiedAtMs<?"); values.append(.integer(until)) }
        if !request.categoryIDs.isEmpty {
            clauses.append("EXISTS(SELECT 1 FROM clip_categories WHERE clipID=clips.id AND categoryID IN(" + request.categoryIDs.map { _ in "?" }.joined(separator: ",") + "))")
            values += request.categoryIDs.sorted().map(SQLValue.text)
        }
        let order = request.categoryIDs.count == 1 ? "(SELECT position FROM clip_categories WHERE clipID=clips.id AND categoryID=?),id" : "lastCopiedAtMs DESC,id"
        return (clauses.joined(separator: " AND "), values, order)
    }
    /// 最新加入/重新拖入批次置前，只写本批归属，不重排整个分类或改变复制身份，by AI.Coding。
    private func prependCategoryItems(_ ids: [ClipID], categoryID: String, db: SQLiteConnection) throws {
        guard !ids.isEmpty else { return }
        var minimum = try db.scalarInt("SELECT COALESCE(MIN(position),0) FROM clip_categories WHERE categoryID=?", [.text(categoryID)])
        // 删除头部后仍为有效撤销包保留位置，避免恢复时与新拖入项同位置，by AI.Coding。
        if let packet = undoPacket, packet.expires > clock.now() {
            for row in packet.tables["clip_categories"] ?? [] where row.text("categoryID") == categoryID {
                minimum = min(minimum, row.int("position"))
            }
        }
        let first = minimum - Int64(ids.count)
        for (index, id) in ids.enumerated() {
            try db.run("INSERT INTO clip_categories(categoryID,clipID,position) VALUES(?,?,?) ON CONFLICT(categoryID,clipID) DO UPDATE SET position=excluded.position", [.text(categoryID), .text(id), .integer(first + Int64(index))])
        }
    }
    /// 分类与板内记录移动一次提交，不刷新复制身份。
    public func moveCategory(id: String, delta: Int) throws {
        let ordered = try categories().map(\.id)
        guard let index = ordered.firstIndex(of: id) else { throw CategoryError.notFound }
        var next = ordered; next.swapAt(index, min(next.count - 1, max(0, index + delta)))
        let settings = try settings()
        try mutate(quota: settings.quotaBytes) { db in
            for (position, id) in next.enumerated() { try db.run("UPDATE categories SET position=? WHERE id=?", [.integer(Int64(position)), .text(id)]) }
        }
    }
    public func moveItem(id: ClipID, categoryID: String, delta: Int) throws {
        var ids = try strategy.read { try $0.rows("SELECT clipID FROM clip_categories WHERE categoryID=? ORDER BY position,clipID", [.text(categoryID)]).map { $0.text("clipID") } }
        guard let index = ids.firstIndex(of: id) else { throw StoreError.notFound }
        ids.swapAt(index, min(ids.count - 1, max(0, index + delta)))
        let settings = try settings()
        try mutate(quota: settings.quotaBytes) { db in
            for (position, id) in ids.enumerated() { try db.run("UPDATE clip_categories SET position=? WHERE categoryID=? AND clipID=?", [.integer(Int64(position)), .text(categoryID), .text(id)]) }
        }
    }
    /// 来源建议来自本地元数据，不加载载荷、不记录搜索正文。
    public func sources() throws -> [SourceAttribution] {
        try strategy.read { db in try db.rows("SELECT sourceBundleID,MIN(sourceName) AS sourceName,MIN(sourceBasis) AS sourceBasis FROM clips GROUP BY COALESCE(sourceBundleID,'') ORDER BY sourceName").map { .init(bundleID: $0.text("sourceBundleID").isEmpty ? nil : $0.text("sourceBundleID"), name: $0.text("sourceName"), basis: $0.text("sourceBasis")) } }
    }
    /// 删除包只驻留内存，先估算预算，超预算不读取大正文。
    private func makeUndo(_ change: HistoryChange) throws -> UndoPacket? {
        guard case .delete(let ids) = change, !ids.isEmpty, ids.count <= 4096 else { return nil }
        return try strategy.read { db in
            let placeholders = Set(ids).map { _ in "?" }.joined(separator: ",")
            let values = Set(ids).sorted().map(SQLValue.text)
            let blobCondition = "digest IN(SELECT blobDigest FROM representations WHERE clipID IN(" + placeholders + "))"
            let bytes = try db.scalarInt("SELECT COALESCE(SUM(byteCount),0) FROM blobs WHERE " + blobCondition, values)
            let metadata = try db.scalarInt("SELECT COALESCE(SUM(length(CAST(previewText AS BLOB))+COALESCE(length(CAST(title AS BLOB))*2,0)),0) FROM clips WHERE id IN(" + placeholders + ")", values)
            let texts = try db.scalarInt("SELECT COALESCE(SUM(length(CAST(plainText AS BLOB))+length(CAST(normalizedText AS BLOB))),0) FROM text_content WHERE clipID IN(" + placeholders + ")", values)
            let declarations = try db.scalarInt("SELECT COALESCE(SUM(length(CAST(declaredTypes AS BLOB))),0) FROM items WHERE clipID IN(" + placeholders + ")", values)
            guard bytes + metadata + texts + declarations + Int64(ids.count) * 8192 <= 50 * MiB else { return nil }
            var tables: [String: [[String: SQLValue]]] = [:]
            tables["clips"] = try db.rows("SELECT * FROM clips WHERE id IN(" + placeholders + ")", values)
            for table in ["items", "representations", "text_content", "clip_categories"] {
                tables[table] = try db.rows("SELECT * FROM " + table + " WHERE clipID IN(" + placeholders + ")", values)
            }
            tables["blobs"] = try db.rows("SELECT * FROM blobs WHERE " + blobCondition, values)
            return UndoPacket(expires: clock.now() + 30_000, tables: tables, bytes: bytes + metadata + texts + declarations + Int64(ids.count) * 8192)
        }
    }
    /// 到期主动释放内存正文，不能只隐藏撤销入口。
    private func clearUndo(expires: Instant) { if undoPacket?.expires == expires { undoPacket = nil }; undoExpiry = nil }
    public func undoAvailable() -> Bool {
        if let packet = undoPacket, packet.expires > clock.now() { return true }
        undoPacket = nil; return false
    }
    /// 当前规则与配额重新检查，撤销不允许淘汰任何已有历史。
    public func undoDelete() throws {
        guard let packet = undoPacket, packet.expires > clock.now() else { undoPacket = nil; throw StoreError.notFound }
        let settings = try settings(), at = clock.now()
        try mutate(quota: settings.quotaBytes, growth: packet.bytes) { db in
            for row in packet.tables["clips"] ?? [] {
                if settings.excludedBundleIDs.contains(row.text("sourceBundleID")), row.text("sourceBasis") == "declared" { throw StoreError.policyChanged }
                guard try db.scalarInt("SELECT COUNT(*) FROM clips WHERE contentHash=? OR id=?", [.text(row.text("contentHash")), .text(row.text("id"))]) == 0 else { throw StoreError.stalePreview }
                let memberships = (packet.tables["clip_categories"] ?? []).filter { $0.text("clipID") == row.text("id") }
                let protected = try memberships.contains { try db.scalarInt("SELECT COUNT(*) FROM categories WHERE id=?", [.text($0.text("categoryID"))]) > 0 }
                let withinRetention = retentionCutoff(settings: settings, at: at).map { row.int("lastCopiedAtMs") > $0 } ?? true
                guard row.int("isFavorite") == 1 || protected || withinRetention else { throw StoreError.notFound }
            }
            for table in ["clips", "items", "blobs", "representations", "text_content", "clip_categories"] {
                for row in packet.tables[table] ?? [] {
                    if table == "clip_categories", try db.scalarInt("SELECT COUNT(*) FROM categories WHERE id=?", [.text(row.text("categoryID"))]) == 0 { continue }
                    let columns = row.keys.sorted()
                    let verb = table == "blobs" ? "INSERT OR IGNORE" : "INSERT"
                    try db.run(verb + " INTO " + table + "(" + columns.joined(separator: ",") + ") VALUES(" + columns.map { _ in "?" }.joined(separator: ",") + ")", columns.map { row[$0]! })
                }
            }
        }
        undoPacket = nil; undoExpiry?.cancel(); undoExpiry = nil
    }

    /// 只公开只读延迟导出句柄，拖拽开始只查询类型和版本，不读取图片正文。
    public func exportAccess(id: ClipID) throws -> ClipExportAccess {
        let metadata = try metadata(id: id, at: clock.now())
        let types = try strategy.read { try $0.rows("SELECT DISTINCT type FROM representations WHERE clipID=? ORDER BY type", [.text(id)]).map { $0.text("type") } }
        return ClipExportAccess(database: strategy.databaseURL, id: id, revision: metadata.revision, types: types, contentHash: try strategy.read { try $0.scalarText("SELECT contentHash FROM clips WHERE id=?", [.text(id)]) })
    }
    /// 导出仅占用自有临时空间，拒绝超配额，不淘汰历史；10分钟内文件租约保留。
    public func writeExport(_ data: Data, id: ClipID, revision: Int64, fileExtension: String = "png") throws -> URL {
        guard ["png", "tiff", "jpg"].contains(fileExtension) else { throw StoreError.invalidSettings }
        _ = try metadata(id: id, at: clock.now())
        guard Int64(data.count) <= 50 * MiB else { throw StoreError.stalePreview }
        let settings = try settings(), usage = try usage()
        guard usage.temporary + Int64(data.count) + 8192 <= 50 * MiB, usage.measuredTotal + Int64(data.count) + 8192 <= settings.quotaBytes else { throw StoreError.quotaExceeded }
        let directory = strategy.root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        do { try data.write(to: file, options: .atomic); guard try self.usage().measuredTotal <= settings.quotaBytes else { throw StoreError.quotaExceeded }; return file }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    /// 仅清理本应用导出目录中过期文件；不碰原件，不提前回收交给目标的租约。
    public func cleanExports() throws {
        let directory = strategy.root.appendingPathComponent("Exports")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values.contentModificationDate, date.timeIntervalSinceNow < -600 { try FileManager.default.removeItem(at: file) }
        }
    }

}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
