import Foundation
import XCTest
import Synchronization
@_spi(Testing) import AgentSessionStorage

private struct Record: AgentSessionIndexRecord, Equatable {
    var id: UUID
    var filename: String
    var activityDate: Date
    var savedAt: Date
    var name: String
    var lastIndexedAt: Date
    func matchesIndexedSessionMetadata(_ other: Self) -> Bool {
        id == other.id && filename == other.filename && activityDate == other.activityDate && savedAt == other.savedAt && name == other.name
    }
}
private struct Quarantine: AgentSessionIndexQuarantine, Equatable {
    var filename: String
    var observedFileSize: Int64?
    var observedFileModificationDate: Date?
    var errorDescription: String
    var lastAttemptedAt: Date
}
private struct Index: AgentSessionIndexDocument, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var generatedAt: Date
    var lastReconciledAt: Date?
    var entries: [Record]
    var quarantinedFiles: [Quarantine]
    init(schemaVersion: Int = 1, generatedAt: Date = Date(timeIntervalSince1970: 100), lastReconciledAt: Date? = nil, entries: [Record] = [], quarantinedFiles: [Quarantine] = []) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.lastReconciledAt = lastReconciledAt
        self.entries = entries; self.quarantinedFiles = quarantinedFiles
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, lastReconciledAt, entries, quarantinedFiles }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? -1
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        lastReconciledAt = try values.decodeIfPresent(Date.self, forKey: .lastReconciledAt)
        entries = try values.decodeIfPresent([Record].self, forKey: .entries) ?? []
        quarantinedFiles = try values.decodeIfPresent([Quarantine].self, forKey: .quarantinedFiles) ?? []
    }
}
private enum FixtureError: Error, Equatable { case missing, write, corrupt }
private final class MemoryFiles: Sendable {
    struct State {
        var values: [URL: Data] = [:]
        var modified: [URL: Date] = [:]
        var reads = 0
        var writes = 0
        var scans = 0
        var failWrites = false
    }
    let state = Mutex(State())
    func put(_ data: Data, at url: URL, modified: Date = .distantPast) { state.withLock { $0.values[url.standardizedFileURL] = data; $0.modified[url.standardizedFileURL] = modified } }
    var io: AgentSessionIndexFileSystem {
        .init(exists: { [self] url in state.withLock { $0.values[url.standardizedFileURL] != nil } },
              read: { [self] url in try state.withLock { state in state.reads += 1; guard let value = state.values[url.standardizedFileURL] else { throw FixtureError.missing }; return value } },
              write: { [self] data, url in try state.withLock { state in state.writes += 1; if state.failWrites { throw FixtureError.write }; state.values[url.standardizedFileURL] = data } },
              list: { [self] folder in state.withLock { state in state.scans += 1; return state.values.keys.filter { $0.deletingLastPathComponent() == folder.standardizedFileURL && !$0.lastPathComponent.starts(with: ".") } } },
              observe: { [self] url in state.withLock { state in .init(size: state.values[url.standardizedFileURL].map { Int64($0.count) }, modified: state.modified[url.standardizedFileURL]) } })
    }
}
@MainActor
final class AgentSessionStorageTests: XCTestCase {
    private typealias Store = AgentSessionMetadataIndexStore<Index>
    private let folder = URL(fileURLWithPath: "/host/A/Sessions", isDirectory: true)
    private let layout = AgentSessionIndexLayout(indexFilename: "Index.json", sessionFilePrefix: "Session-", sessionFileExtension: "json")
    private let date = Date(timeIntervalSince1970: 100)
    private func store(_ fs: MemoryFiles, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> Store {
        .init(layout: layout, files: fs.io, now: { Date(timeIntervalSince1970: 100) }, sleep: sleep)
    }
    private func row(_ id: String = "00000000-0000-0000-0000-000000000001", filename: String = "Session-one.json", activity: Double = 10, saved: Double = 9, name: String = "fixture", indexed: Double = 0) -> Record {
        .init(id: UUID(uuidString: id)!, filename: filename, activityDate: Date(timeIntervalSince1970: activity), savedAt: Date(timeIntervalSince1970: saved), name: name, lastIndexedAt: Date(timeIntervalSince1970: indexed))
    }
    func testMissingIndexDoesNotScanSessionFiles() {
        let fs = MemoryFiles(); let s = store(fs)
        XCTAssertNil(s.read(folder: folder)); XCTAssertEqual(fs.state.withLock { $0.scans }, 0)
    }
    func testDiskThenMemoryReadUsesCacheAndCanonicalFolderKey() throws {
        let fs = MemoryFiles(); let s = store(fs); fs.put(try JSONEncoder().encode(Index(entries: [row()])), at: s.indexURL(in: folder))
        XCTAssertEqual(s.read(folder: folder)?.source, .diskIndex)
        XCTAssertEqual(s.read(folder: folder.appendingPathComponent("../Sessions", isDirectory: true))?.source, .memoryIndex)
        XCTAssertEqual(fs.state.withLock { $0.reads }, 1); XCTAssertEqual(fs.state.withLock { $0.scans }, 0)
    }
    func testForcedDiskReadBypassesMemoryAndInvalidDataClearsCache() throws {
        let fs = MemoryFiles(); let s = store(fs); try s.write(Index(entries: [row()]), folder: folder)
        fs.put(Data("bad".utf8), at: s.indexURL(in: folder))
        XCTAssertNotNil(s.read(folder: folder)); XCTAssertNil(s.read(folder: folder, preferCache: false)); XCTAssertNil(s.cachedEntryCount(folder: folder))
    }
    func testFutureAndMissingSchemaFailClosedWithoutRewritingDisk() throws {
        for data in [try JSONEncoder().encode(Index(schemaVersion: 2)), Data(#"{"generatedAt":0,"entries":[],"quarantinedFiles":[]}"#.utf8)] {
            let fs = MemoryFiles(); let s = store(fs); fs.put(data, at: s.indexURL(in: folder))
            XCTAssertNil(s.read(folder: folder)); XCTAssertEqual(fs.state.withLock { $0.writes }, 0)
        }
    }
    func testWritePreservesSchemaKeysAndSortsByActivitySavedTimeAndUUID() throws {
        let fs = MemoryFiles(); let s = store(fs)
        let a = row(); let b = row("00000000-0000-0000-0000-000000000002", filename: "Session-two.json", activity: 20)
        let c = row("00000000-0000-0000-0000-000000000003", filename: "Session-three.json", activity: 10, saved: 20)
        try s.write(Index(schemaVersion: 9, entries: [a, c, b]), folder: folder)
        let data = try XCTUnwrap(fs.state.withLock { $0.values[s.indexURL(in: folder)] })
        let decoded = try JSONDecoder().decode(Index.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1); XCTAssertEqual(decoded.entries, [b, c, a])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "generatedAt", "entries", "quarantinedFiles"])
    }
    func testWriteFailureKeepsNormalizedMemoryIndexAndPropagatesError() {
        let fs = MemoryFiles(); let s = store(fs); fs.state.withLock { $0.failWrites = true }
        XCTAssertThrowsError(try s.write(Index(entries: [row()]), folder: folder)) { XCTAssertEqual($0 as? FixtureError, .write) }
        XCTAssertEqual(s.cachedEntryCount(folder: folder), 1); XCTAssertEqual(s.read(folder: folder)?.source, .memoryIndex)
    }
    func testUpsertReplacesMatchingIDOrFilenameAndPreservesOtherRows() throws {
        let fs = MemoryFiles(); let s = store(fs)
        let a = row(); let b = row("00000000-0000-0000-0000-000000000002", filename: "Session-two.json")
        try s.write(Index(entries: [a, b]), folder: folder)
        let replacement = row("00000000-0000-0000-0000-000000000003", filename: a.filename, name: "new")
        s.upsert(replacement, folder: folder)
        XCTAssertEqual(Set(s.read(folder: folder)!.index.entries.map(\.id)), [b.id, replacement.id])
        XCTAssertEqual(s.read(folder: folder)?.index.generatedAt, date)
    }
    func testUpsertWithoutIndexCreatesOnlySuppliedRecordRatherThanScanning() {
        let fs = MemoryFiles(); let s = store(fs); fs.put(Data("legacy".utf8), at: folder.appendingPathComponent("Session-old.json"))
        s.upsert(row(), folder: folder)
        XCTAssertEqual(s.cachedEntryCount(folder: folder), 1); XCTAssertEqual(fs.state.withLock { $0.scans }, 0)
    }
    func testConditionalUpsertDoesNotCreateIndexAndIgnoresIndexedTimestampOnlyDifference() throws {
        let fs = MemoryFiles(); let s = store(fs); s.upsertIfPresent(row(), folder: folder)
        XCTAssertEqual(fs.state.withLock { $0.writes }, 0)
        try s.write(Index(entries: [row()]), folder: folder)
        let writes = fs.state.withLock { $0.writes }; s.upsertIfPresent(row(indexed: 99), folder: folder)
        XCTAssertEqual(fs.state.withLock { $0.writes }, writes)
        s.upsertIfPresent(row(name: "changed"), folder: folder); XCTAssertEqual(fs.state.withLock { $0.writes }, writes + 1)
    }
    func testRemoveWritesOnlyWhenRecordsChange() throws {
        let fs = MemoryFiles(); let s = store(fs); try s.write(Index(entries: [row()]), folder: folder)
        let writes = fs.state.withLock { $0.writes }; s.remove(matching: { _ in false }, folder: folder)
        XCTAssertEqual(fs.state.withLock { $0.writes }, writes)
        s.remove(matching: { _ in true }, folder: folder); XCTAssertEqual(s.cachedEntryCount(folder: folder), 0)
        XCTAssertEqual(fs.state.withLock { $0.writes }, writes + 1)
    }
    func testScanFiltersPrefixHiddenAndExtensionThenSortsByModificationTime() throws {
        let fs = MemoryFiles(); let s = store(fs)
        let older = folder.appendingPathComponent("Session-one.json"), newer = folder.appendingPathComponent("Session-two.JSON")
        fs.put(Data(), at: older, modified: Date(timeIntervalSince1970: 1)); fs.put(Data(), at: newer, modified: Date(timeIntervalSince1970: 2))
        for name in ["Index.json", "Other.json", ".Session-hidden.json", "Session-wrong.txt"] { fs.put(Data(), at: folder.appendingPathComponent(name)) }
        XCTAssertEqual(try s.sessionFiles(in: folder), [newer, older])
    }
    func testFilenameReconciliationComparesSetsOnly() throws {
        let fs = MemoryFiles(); let s = store(fs); fs.put(Data(), at: folder.appendingPathComponent(row().filename))
        XCTAssertFalse(try s.needsFilenameReconciliation(Index(entries: [row(name: "different")]), folder: folder))
        XCTAssertTrue(try s.needsFilenameReconciliation(Index(), folder: folder))
    }
    func testRebuildQuarantinesMalformedFilesAndRetainsResourceObservationAndTime() async throws {
        let fs = MemoryFiles(); let s = store(fs)
        let good = folder.appendingPathComponent("Session-good.json"), bad = folder.appendingPathComponent("Session-bad.json")
        fs.put(Data([1, 2]), at: good); fs.put(Data([3]), at: bad, modified: date)
        let rebuilt = try await s.rebuild(folder: folder, loadRecord: { url, _, time in
            XCTAssertEqual(time, self.date); if url == bad { throw FixtureError.corrupt }; return self.row(filename: url.lastPathComponent)
        })
        XCTAssertEqual(rebuilt.entries.count, 1); XCTAssertEqual(rebuilt.quarantinedFiles.count, 1)
        let q = try XCTUnwrap(rebuilt.quarantinedFiles.first)
        XCTAssertEqual(q.filename, bad.lastPathComponent); XCTAssertEqual(q.observedFileSize, 1); XCTAssertEqual(q.observedFileModificationDate, date); XCTAssertEqual(q.lastAttemptedAt, date)
        XCTAssertEqual(rebuilt.lastReconciledAt, date)
        let decision = s.scheduleReconciliation(folder: folder, delaySeconds: 0) { _ in XCTFail() }; XCTAssertTrue(decision.alreadyReconciled); XCTAssertFalse(decision.scheduled)
    }
    func testRebuildIsBestEffortOnIndexWriteFailureButReturnsAuthoritativeRecords() async throws {
        let fs = MemoryFiles(); let s = store(fs); fs.put(Data(), at: folder.appendingPathComponent(row().filename)); fs.state.withLock { $0.failWrites = true }
        let rebuilt = try await s.rebuild(folder: folder, loadRecord: { _, _, _ in self.row() })
        XCTAssertEqual(rebuilt.entries.count, 1); XCTAssertEqual(s.cachedEntryCount(folder: folder), 1)
    }
    func testDifferentRootsAndInstancesHaveSeparateCachesAndDiskNamespaces() throws {
        let fs = MemoryFiles(); let a = store(fs), b = store(fs); let other = URL(fileURLWithPath: "/host/B/Sessions")
        try a.write(Index(entries: [row()]), folder: folder); XCTAssertNil(b.cachedEntryCount(folder: folder)); XCTAssertNil(a.read(folder: other))
        try b.write(Index(entries: [row(name: "B")]), folder: other)
        XCTAssertEqual(a.read(folder: folder)?.index.entries.first?.name, "fixture"); XCTAssertEqual(b.read(folder: other)?.index.entries.first?.name, "B")
    }
    func testObservationBeginsBeforeIOAndReportsReadSource() throws {
        let fs = MemoryFiles(); let s = store(fs); var events: [String] = []
        try s.write(Index(), folder: folder, observe: { switch $0 { case .willWrite: events.append("start"); case .write: events.append("done"); default: XCTFail() } })
        XCTAssertEqual(events, ["start", "done"])
        s.clearForTesting(folder: folder); events = []
        _ = s.read(folder: folder, observe: { switch $0 { case .willRead: events.append("start"); case .read(.diskHit, _, _, _, _): events.append("disk"); default: XCTFail() } })
        XCTAssertEqual(events, ["start", "disk"])
    }
    func testDelayedReconciliationCanBePromotedAndDuplicateSchedulesAreIgnored() async throws {
        let fs = MemoryFiles(); let s = store(fs); let delivered = AsyncStream<Store.ReconciliationToken>.makeStream()
        let first = s.scheduleReconciliation(folder: folder, delaySeconds: 2) { delivered.continuation.yield($0) }
        XCTAssertTrue(first.scheduled)
        let duplicate = s.scheduleReconciliation(folder: folder, delaySeconds: 1) { _ in XCTFail() }; XCTAssertTrue(duplicate.alreadyScheduled); XCTAssertFalse(duplicate.scheduled)
        let promoted = s.scheduleReconciliation(folder: folder, delaySeconds: 0) { delivered.continuation.yield($0) }
        XCTAssertTrue(promoted.scheduled); XCTAssertEqual(promoted.delaySeconds, 0)
        var iterator = delivered.stream.makeAsyncIterator(); let firstValue = await iterator.next(); var token = try XCTUnwrap(firstValue)
        if token.delaySeconds > 0 { let nextValue = await iterator.next(); token = try XCTUnwrap(nextValue) }
        await s.performReconciliation(token, loadRecord: { _, _, _ in self.row() })
        XCTAssertFalse(s.isReconciliationScheduled(folder: folder))
    }
    func testForeignReconciliationTokenCannotReadOrWriteAnotherOwnersRoot() async throws {
        let fs = MemoryFiles(); let a = store(fs), b = store(fs); let delivered = AsyncStream<Store.ReconciliationToken>.makeStream()
        a.scheduleReconciliation(folder: folder, delaySeconds: 0) { delivered.continuation.yield($0) }
        var iterator = delivered.stream.makeAsyncIterator(); let value = await iterator.next(); let token = try XCTUnwrap(value)
        await b.performReconciliation(token, loadRecord: { _, _, _ in XCTFail(); return self.row() })
        XCTAssertEqual(fs.state.withLock { $0.scans }, 0); XCTAssertEqual(fs.state.withLock { $0.writes }, 0)
        a.clearForTesting(folder: folder)
    }
    func testFoundationIOUsesSuppliedRootAndPreservesRoundTripBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let s = Store(layout: layout); let value = Index(entries: [row()]); try s.write(value, folder: dir)
        let expected = try JSONEncoder().encode(value); let actual = try Data(contentsOf: s.indexURL(in: dir))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? NSDictionary, try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
        s.clearForTesting(folder: dir); XCTAssertEqual(s.read(folder: dir)?.index, value)
    }
}
