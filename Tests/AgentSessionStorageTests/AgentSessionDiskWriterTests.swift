import Foundation
import XCTest
import Synchronization
@_spi(Testing) import AgentSessionStorage

@MainActor
final class AgentSessionDiskWriterTests: XCTestCase {
    private enum Failure: Error, Equatable { case first, latest }
    private actor Gate {
        let entered = AsyncStream<Void>.makeStream()
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0; entered.continuation.yield(()); entered.continuation.finish() } }
        func release() { waiter?.resume(); waiter = nil }
    }
    private final class Recorder: Sendable {
        let values = Mutex<[String]>([])
        func add(_ value: String) { values.withLock { $0.append(value) } }
        var snapshot: [String] { values.withLock { $0 } }
    }
    private func waitFor(_ count: Int, writer: AgentSessionDiskWriter, url: URL) async {
        for _ in 0..<10_000 { if await writer.pendingWaiterCount(for: url) == count { return }; await Task.yield() }
        XCTFail("Writer did not enqueue expected snapshots")
    }
    func testSameURLCoalescesIntermediateSnapshotAndCompletesEveryWaiterAfterLatestWrite() async throws {
        let gate = Gate(); let record = Recorder(); let url = URL(fileURLWithPath: "/host/A.json")
        let writer = AgentSessionDiskWriter { data, _ in
            let text = String(decoding: data, as: UTF8.self); record.add(text)
            if text == "first" { await gate.wait() }
        }
        let first = Task { try await writer.enqueueAndWait(data: Data("first".utf8), url: url) }
        let entered = await gate.entered; var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        let middle = Task { try await writer.enqueueAndWait(data: Data("middle".utf8), url: url) }
        await waitFor(2, writer: writer, url: url)
        let latest = Task { try await writer.enqueueAndWait(data: Data("latest".utf8), url: url) }
        await waitFor(3, writer: writer, url: url); await gate.release()
        try await first.value; try await middle.value; try await latest.value
        XCTAssertEqual(record.snapshot, ["first", "latest"])
        let waiters = await writer.pendingWaiterCount(for: url); XCTAssertEqual(waiters, 0)
    }
    func testDifferentURLsWriteIndependentlyWhileOneURLIsBlocked() async throws {
        let gate = Gate(); let record = Recorder(); let a = URL(fileURLWithPath: "/host/A.json"), b = URL(fileURLWithPath: "/host/B.json")
        let writer = AgentSessionDiskWriter { data, url in record.add(String(decoding: data, as: UTF8.self)); if url == a { await gate.wait() } }
        let first = Task { try await writer.enqueueAndWait(data: Data("A".utf8), url: a) }
        let entered = await gate.entered; var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        try await writer.enqueueAndWait(data: Data("B".utf8), url: b)
        XCTAssertEqual(record.snapshot, ["A", "B"]); await gate.release(); try await first.value
    }
    func testLastSuccessfulWriteClearsEarlierErrorForAllPendingWaiters() async throws {
        let gate = Gate(); let url = URL(fileURLWithPath: "/host/session.json")
        let writer = AgentSessionDiskWriter { data, _ in if String(decoding: data, as: UTF8.self) == "first" { await gate.wait(); throw Failure.first } }
        let first = Task { try await writer.enqueueAndWait(data: Data("first".utf8), url: url) }
        let entered = await gate.entered; var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        let next = Task { try await writer.enqueueAndWait(data: Data("next".utf8), url: url) }
        await waitFor(2, writer: writer, url: url); await gate.release(); try await first.value; try await next.value
    }
    func testLatestErrorReachesEveryPendingWaiterAndNextQueueCanRecover() async throws {
        let gate = Gate(); let url = URL(fileURLWithPath: "/host/session.json")
        let writer = AgentSessionDiskWriter { data, _ in
            let text = String(decoding: data, as: UTF8.self)
            if text == "first" { await gate.wait() }; if text == "latest" { throw Failure.latest }
        }
        let first = Task { try await writer.enqueueAndWait(data: Data("first".utf8), url: url) }
        let entered = await gate.entered; var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        let next = Task { try await writer.enqueueAndWait(data: Data("latest".utf8), url: url) }
        await waitFor(2, writer: writer, url: url); await gate.release()
        for task in [first, next] { do { try await task.value; XCTFail() } catch { XCTAssertEqual(error as? Failure, .latest) } }
        try await writer.enqueueAndWait(data: Data("recovered".utf8), url: url)
    }
    func testCancelledCallerStillWaitsForDurabilityAndDoesNotCancelSharedWrite() async throws {
        let gate = Gate(); let url = URL(fileURLWithPath: "/host/session.json"); let record = Recorder()
        let writer = AgentSessionDiskWriter { data, _ in await gate.wait(); record.add(String(decoding: data, as: UTF8.self)) }
        let caller = Task { try await writer.enqueueAndWait(data: Data("snapshot".utf8), url: url) }
        let entered = await gate.entered; var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next(); caller.cancel(); await gate.release()
        try await caller.value; XCTAssertEqual(record.snapshot, ["snapshot"])
    }
    func testFoundationAtomicWriteKeepsCallerBytesAndReportsMissingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let writer = AgentSessionDiskWriter(); let url = root.appendingPathComponent("snapshot.json")
        let bytes = Data(#"{"serializationVersion":3,"opaque":"fixture"}"#.utf8)
        try await writer.enqueueAndWait(data: bytes, url: url); XCTAssertEqual(try Data(contentsOf: url), bytes)
        do { try await writer.enqueueAndWait(data: bytes, url: root.appendingPathComponent("missing/snapshot.json")); XCTFail() } catch {}
    }
}
