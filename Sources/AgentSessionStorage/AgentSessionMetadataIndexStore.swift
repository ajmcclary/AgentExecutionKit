import Foundation

/// Caller-actor-owned index/cache/reconciliation service. Session files remain
/// authoritative; the index is a repairable cache. No mutable cache/task storage
/// escapes. Keep one instance under one host or execution-service actor.
public final class AgentSessionMetadataIndexStore<Index: AgentSessionIndexDocument> {
    public enum Source: String, Sendable { case memoryIndex, diskIndex }
    public struct ReadResult: Sendable {
        public let index: Index
        public let source: Source
    }
    public enum ReadStatus: Sendable { case memoryHit, missing, schemaMismatch, diskHit, failed }
    public enum Observation: Sendable {
        case willRead, willWrite, willRemove, willScan, willCheck, willRebuild
        case read(ReadStatus, entries: Int?, quarantined: Int?, bytes: Int?, error: String?)
        case write(entries: Int, quarantined: Int)
        case remove(before: Int, after: Int, changed: Bool)
        case scan(sessionFiles: Int, directoryEntries: Int)
        case reconciliationCheck(needsRebuild: Bool, sessionFiles: Int, indexedEntries: Int)
        case rebuild(sessionFiles: Int, records: Int, quarantined: Int)
    }
    public struct ReconciliationToken: Sendable, Equatable {
        fileprivate let id: UUID
        fileprivate let owner: UUID
        public let folder: URL
        public let delaySeconds: TimeInterval
    }
    public struct ScheduleDecision: Sendable {
        public let delaySeconds: TimeInterval
        public let alreadyScheduled: Bool
        public let alreadyReconciled: Bool
        public let scheduled: Bool
    }
    private struct Scheduled {
        let token: ReconciliationToken
        let task: Task<Void, Never>
    }
    private let ownerID = UUID()
    private let layout: AgentSessionIndexLayout
    private let files: AgentSessionIndexFileSystem
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [URL: Index] = [:]
    private var scheduled: [URL: Scheduled] = [:]
    private var reconciled: Set<URL> = []
    public init(layout: AgentSessionIndexLayout, files: AgentSessionIndexFileSystem = .foundation,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    let ns = UInt64(min(seconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: ns)
                }) {
        self.layout = layout; self.files = files; self.now = now; self.sleep = sleep
    }
    public static func sortedRecords(_ records: [Index.Record]) -> [Index.Record] {
        records.sorted {
            if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
            if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public func fileObservation(at url: URL) -> AgentSessionFileObservation { files.observe(url) }
    public func indexURL(in folder: URL) -> URL { folder.appendingPathComponent(layout.indexFilename) }
    public func read(folder: URL, preferCache: Bool = true, observe: (Observation) -> Void = { _ in }) -> ReadResult? {
        observe(.willRead)
        let key = folder.standardizedFileURL
        if preferCache, let cached = cache[key] {
            guard cached.schemaVersion == Index.currentSchemaVersion else { cache.removeValue(forKey: key); return nil }
            observe(.read(.memoryHit, entries: cached.entries.count, quarantined: cached.quarantinedFiles.count, bytes: nil, error: nil))
            return .init(index: cached, source: .memoryIndex)
        }
        let url = indexURL(in: folder)
        guard files.exists(url) else {
            cache.removeValue(forKey: key); observe(.read(.missing, entries: nil, quarantined: nil, bytes: nil, error: nil)); return nil
        }
        do {
            let data = try files.read(url)
            let index = try decoder.decode(Index.self, from: data)
            guard index.schemaVersion == Index.currentSchemaVersion else {
                cache.removeValue(forKey: key); observe(.read(.schemaMismatch, entries: index.entries.count, quarantined: nil, bytes: nil, error: nil)); return nil
            }
            cache[key] = index
            observe(.read(.diskHit, entries: index.entries.count, quarantined: index.quarantinedFiles.count, bytes: data.count, error: nil))
            return .init(index: index, source: .diskIndex)
        } catch {
            cache.removeValue(forKey: key); observe(.read(.failed, entries: nil, quarantined: nil, bytes: nil, error: String(describing: error))); return nil
        }
    }
    public func write(_ index: Index, folder: URL, observe: (Observation) -> Void = { _ in }) throws {
        observe(.willWrite)
        var normalized = index
        normalized.schemaVersion = Index.currentSchemaVersion
        normalized.entries = Self.sortedRecords(normalized.entries)
        let data = try encoder.encode(normalized)
        cache[folder.standardizedFileURL] = normalized
        try files.write(data, indexURL(in: folder))
        observe(.write(entries: normalized.entries.count, quarantined: normalized.quarantinedFiles.count))
    }
    public func upsert(_ record: Index.Record, folder: URL, observe: (Observation) -> Void = { _ in }) {
        let key = folder.standardizedFileURL
        var index = cache[key] ?? read(folder: folder, observe: observe)?.index
            ?? Index(schemaVersion: Index.currentSchemaVersion, generatedAt: now(), lastReconciledAt: nil, entries: [], quarantinedFiles: [])
        index.entries.removeAll { $0.id == record.id || $0.filename == record.filename }
        index.entries.append(record); index.generatedAt = now(); cache[key] = index
        try? write(index, folder: folder, observe: observe)
    }
    public func upsertIfPresent(_ record: Index.Record, folder: URL, observe: (Observation) -> Void = { _ in }) {
        guard var index = read(folder: folder, observe: observe)?.index else { return }
        if let existing = index.entries.first(where: { $0.id == record.id }), existing.matchesIndexedSessionMetadata(record) { return }
        index.entries.removeAll { $0.id == record.id || $0.filename == record.filename }
        index.entries.append(record); index.generatedAt = now()
        try? write(index, folder: folder, observe: observe)
    }
    public func remove(matching predicate: (Index.Record) -> Bool, folder: URL, observe: (Observation) -> Void = { _ in }) {
        observe(.willRemove)
        guard var index = read(folder: folder, observe: observe)?.index else { observe(.remove(before: 0, after: 0, changed: false)); return }
        let before = index.entries.count
        index.entries.removeAll(where: predicate)
        let changed = before != index.entries.count
        defer { observe(.remove(before: before, after: index.entries.count, changed: changed)) }
        guard changed else { return }
        index.generatedAt = now(); try? write(index, folder: folder, observe: observe)
    }
    public func sessionFiles(in folder: URL, observe: (Observation) -> Void = { _ in }) throws -> [URL] {
        observe(.willScan)
        let all = try files.list(folder)
        let sessions = all.filter { $0.pathExtension.lowercased() == layout.sessionFileExtension && $0.lastPathComponent.starts(with: layout.sessionFilePrefix) }
        let sorted = sessions.sorted { (files.observe($0).modified ?? .distantPast) > (files.observe($1).modified ?? .distantPast) }
        observe(.scan(sessionFiles: sorted.count, directoryEntries: all.count)); return sorted
    }
    public func needsFilenameReconciliation(_ index: Index, folder: URL, observe: (Observation) -> Void = { _ in }) throws -> Bool {
        observe(.willCheck)
        let names = Set(try sessionFiles(in: folder, observe: observe).map(\.lastPathComponent))
        let indexed = Set(index.entries.map(\.filename)); let needs = names != indexed
        observe(.reconciliationCheck(needsRebuild: needs, sessionFiles: names.count, indexedEntries: indexed.count)); return needs
    }
    public func rebuild(folder: URL,
                        loadRecord: (URL, AgentSessionFileObservation, Date) async throws -> Index.Record,
                        observe: (Observation) -> Void = { _ in },
                        isolation: isolated (any Actor)? = #isolation) async throws -> Index {
        observe(.willRebuild)
        let date = now(); let sessions = try sessionFiles(in: folder, observe: observe)
        var records: [Index.Record] = []; var quarantine: [Index.Quarantine] = []
        records.reserveCapacity(sessions.count)
        for url in sessions {
            let observation = files.observe(url)
            do { records.append(try await loadRecord(url, observation, date)) }
            catch { quarantine.append(.init(filename: url.lastPathComponent, observedFileSize: observation.size,
                                             observedFileModificationDate: observation.modified, errorDescription: String(describing: error), lastAttemptedAt: date)) }
        }
        let index = Index(schemaVersion: Index.currentSchemaVersion, generatedAt: date, lastReconciledAt: date,
                          entries: Self.sortedRecords(records), quarantinedFiles: quarantine)
        try? write(index, folder: folder, observe: observe)
        reconciled.insert(folder.standardizedFileURL)
        observe(.rebuild(sessionFiles: sessions.count, records: records.count, quarantined: quarantine.count)); return index
    }
    @discardableResult public func scheduleReconciliation(folder: URL, delaySeconds: TimeInterval,
                          deliver: @escaping @Sendable (ReconciliationToken) async -> Void) -> ScheduleDecision {
        let key = folder.standardizedFileURL; let existing = scheduled[key]
        let wasReconciled = reconciled.contains(key); let delay = max(delaySeconds, 0)
        let promotes = existing.map { $0.token.delaySeconds > 0 && delay == 0 } ?? false
        let willSchedule = !wasReconciled && (existing == nil || promotes)
        let decision = ScheduleDecision(delaySeconds: delay, alreadyScheduled: existing != nil, alreadyReconciled: wasReconciled, scheduled: willSchedule)
        guard willSchedule else { return decision }
        if promotes { existing?.task.cancel() }
        let token = ReconciliationToken(id: UUID(), owner: ownerID, folder: folder, delaySeconds: delay)
        let task = Task(priority: .utility) { await deliver(token) }
        scheduled[key] = .init(token: token, task: task)
        return decision
    }
    public func performReconciliation(_ token: ReconciliationToken,
                          loadRecord: (URL, AgentSessionFileObservation, Date) async throws -> Index.Record,
                          observe: (Observation) -> Void = { _ in },
                          isolation: isolated (any Actor)? = #isolation) async {
        guard token.owner == ownerID else { return }
        let key = token.folder.standardizedFileURL
        defer { if scheduled[key]?.token.id == token.id { scheduled.removeValue(forKey: key) } }
        if token.delaySeconds > 0 {
            do { try await sleep(token.delaySeconds); try Task.checkCancellation() }
            catch { return }
        }
        _ = try? await rebuild(folder: token.folder, loadRecord: loadRecord, observe: observe, isolation: isolation)
    }
    public func cachedEntryCount(folder: URL) -> Int? { cache[folder.standardizedFileURL]?.entries.count }
    public func isReconciliationScheduled(folder: URL) -> Bool { scheduled[folder.standardizedFileURL] != nil }
    @_spi(Testing) public func clearForTesting(folder: URL) {
        let key = folder.standardizedFileURL; cache.removeValue(forKey: key)
        scheduled[key]?.task.cancel(); scheduled.removeValue(forKey: key); reconciled.remove(key)
    }
    @_spi(Testing) public func markReconciledForTesting(folder: URL) { reconciled.insert(folder.standardizedFileURL) }
}
