import XCTest
import AgentClaudeClient

@MainActor
final class ClaudeNativeConnectionLifecycleTests: XCTestCase {
    private enum Failure: Error, Equatable { case refused, spawn, readers, write }
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testAdmissionSettingsSpawnEpochReadersAndRegistrationAreOrdered() async throws {
        let owner = ClaudeNativeClientLifecycle(); var order: [String] = []
        try await owner.startTransport(hasProcess: { false }, resetEpoch: { order.append("reset") },
            admit: { order.append("admit"); return "immutable-launch" },
            adopt: { XCTAssertEqual($0, "immutable-launch"); order.append("adopt") },
            spawn: { XCTAssertEqual($0, "immutable-launch"); order.append("spawn"); return 42 },
            beginEpoch: { order.append("epoch") }, startReaders: { order.append("readers") },
            invalidateReaders: { XCTFail() }, registerPID: { XCTAssertEqual($0, 42); order.append("register") })
        XCTAssertEqual(order, ["reset", "admit", "adopt", "spawn", "epoch", "readers", "register"])
    }
    func testExistingProcessFastPathDoesNotResetOrReclassify() async throws {
        try await ClaudeNativeClientLifecycle().startTransport(hasProcess: { true }, resetEpoch: { XCTFail() },
            admit: { XCTFail(); return 0 }, adopt: { _ in XCTFail() }, spawn: { _ in XCTFail(); return 0 },
            beginEpoch: { XCTFail() }, startReaders: { XCTFail() }, invalidateReaders: { XCTFail() }, registerPID: { _ in XCTFail() })
    }
    func testAdmissionRefusalAndSpawnFailureNeverStartReadersOrRegisterPID() async {
        for failedSpawn in [false, true] {
            var order: [String] = []
            do {
                try await ClaudeNativeClientLifecycle().startTransport(hasProcess: { false }, resetEpoch: { order.append("reset") },
                    admit: { () async throws -> Int in order.append("admit"); if !failedSpawn { throw Failure.refused }; return 1 },
                    adopt: { _ in order.append("adopt") }, spawn: { _ in order.append("spawn"); throw Failure.spawn },
                    beginEpoch: { XCTFail() }, startReaders: { XCTFail() }, invalidateReaders: { XCTFail() }, registerPID: { _ in XCTFail() })
                XCTFail()
            } catch { XCTAssertEqual(error as? Failure, failedSpawn ? .spawn : .refused) }
            XCTAssertEqual(order, failedSpawn ? ["reset", "admit", "adopt", "spawn"] : ["reset", "admit"])
        }
    }
    func testReaderFailureAwaitsCleanupBeforeReportingInitializationFailure() async {
        let owner = ClaudeNativeClientLifecycle(); let gate = Gate(); var order: [String] = []
        let task = Task {
            do {
                try await owner.startTransport(hasProcess: { false }, resetEpoch: {}, admit: { 1 }, adopt: { _ in }, spawn: { _ in 42 },
                    beginEpoch: {}, startReaders: { order.append("readers"); throw Failure.readers },
                    invalidateReaders: { order.append("invalidate"); await gate.wait(); order.append("reaped") }, registerPID: { _ in XCTFail() })
                XCTFail()
            } catch { XCTAssertEqual(error as? ClaudeNativeClientError, .initializationFailed("Failed to start Claude process readers: \(Failure.readers.localizedDescription)")); order.append("failed") }
        }
        while !(await gate.entered) { await Task.yield() }
        XCTAssertEqual(order, ["readers", "invalidate"])
        await gate.release(); await task.value
        XCTAssertEqual(order, ["readers", "invalidate", "reaped", "failed"])
    }
    func testStartupWaitsForPriorTransportTeardownBeforeProcessCheck() async throws {
        let owner = ClaudeNativeClientLifecycle(); let gate = Gate(); var checked = false
        let teardown = Task { await owner.tearDownTransport(invalidate: { nil }, clearRegistration: { await gate.wait() }) }
        while !(await gate.entered) { await Task.yield() }
        let startup = Task { try await owner.startTransport(hasProcess: { checked = true; return true }, resetEpoch: { XCTFail() },
            admit: { XCTFail(); return 0 }, adopt: { _ in XCTFail() }, spawn: { _ in XCTFail(); return 0 },
            beginEpoch: { XCTFail() }, startReaders: { XCTFail() }, invalidateReaders: { XCTFail() }, registerPID: { _ in XCTFail() }) }
        await Task.yield(); XCTAssertFalse(checked)
        await gate.release(); await teardown.value; try await startup.value
        XCTAssertTrue(checked)
    }
    func testEOFFlushAndReconcilePrecedeReapAndFinalErrorCompletionOrder() async {
        var order: [String] = []
        await ClaudeNativeClientLifecycle().handleEOF(generation: 1, currentGeneration: { 1 }, hasProcess: { true },
            observeEOF: { order.append("eof") }, flush: { order.append("flush"); return nil }, failProtocol: { _ in XCTFail() },
            prepareClose: { order.append("reconcile"); return "pending-turn" }, teardownTransport: { order.append("reap") },
            finishClose: { XCTAssertEqual($0, "pending-turn"); order += ["retire", "error", "completion", "clear", "finish"] })
        XCTAssertEqual(order, ["eof", "flush", "reconcile", "reap", "retire", "error", "completion", "clear", "finish"])
    }
    func testStaleEOFAbsentProcessAndShutdownDoNotFlushOrClose() async {
        for state in 0..<3 {
            let owner = ClaudeNativeClientLifecycle()
            if state == 2 {
                await owner.shutdown(actions: .init(prepare: {}, teardownTransport: {}, retireEpoch: {}, finish: {}),
                    preparer: .init(isMCPServerRunning: { true }, prepareConfigFile: { nil }, cleanupConfigFile: { _ in }))
            }
            await owner.handleEOF(generation: 1, currentGeneration: { state == 0 ? 2 : 1 }, hasProcess: { state != 1 },
                observeEOF: { XCTFail() }, flush: { XCTFail(); return nil }, failProtocol: { _ in XCTFail() },
                prepareClose: { XCTFail(); return 0 }, teardownTransport: { XCTFail() }, finishClose: { _ in XCTFail() })
        }
    }
    func testEOFFailedFlushRechecksProcessGenerationAndShutdownBeforeClosing() async {
        for state in 0..<3 {
            let owner = ClaudeNativeClientLifecycle(); var generation: UInt64 = 1; var hasProcess = true; var order: [String] = []
            await owner.handleEOF(generation: 1, currentGeneration: { generation }, hasProcess: { hasProcess }, observeEOF: {},
                flush: { "decode-failure" }, failProtocol: { message in
                    XCTAssertEqual(message, "decode-failure"); order.append("failure")
                    if state == 0 { generation = 2 }
                    if state == 1 { hasProcess = false }
                    if state == 2 {
                        await owner.shutdown(actions: .init(prepare: {}, teardownTransport: {}, retireEpoch: {}, finish: {}),
                            preparer: .init(isMCPServerRunning: { true }, prepareConfigFile: { nil }, cleanupConfigFile: { _ in }))
                    }
                }, prepareClose: { XCTFail(); return 0 }, teardownTransport: { XCTFail() }, finishClose: { _ in XCTFail() })
            XCTAssertEqual(order, ["failure"])
        }
    }
    func testEOFReplacedConnectionDuringReapingCannotFinishNewEvents() async {
        var generation: UInt64 = 1; let gate = Gate(); var finished = false
        let task = Task {
            await ClaudeNativeClientLifecycle().handleEOF(generation: 1, currentGeneration: { generation }, hasProcess: { true },
                observeEOF: {}, flush: { nil }, failProtocol: { _ in XCTFail() }, prepareClose: { 0 },
                teardownTransport: { await gate.wait() }, finishClose: { _ in finished = true })
        }
        while !(await gate.entered) { await Task.yield() }
        generation = 2; await gate.release(); await task.value
        XCTAssertFalse(finished)
    }
    func testWriteFailuresKeepOriginalErrorAndCaptureGenerationBeforeWrite() throws {
        let owner = ClaudeNativeClientLifecycle(); let bytes = Data("payload".utf8)
        for enabled in [false, true] {
            var generation: UInt64 = 7; var scheduled: [UInt64] = []
            XCTAssertThrowsError(try owner.writeLine(bytes, shutdownOnFailure: enabled, hasProcess: { true }, generation: { generation },
                write: { XCTAssertEqual($0, bytes); generation = 8; throw Failure.write }, scheduleShutdown: { scheduled.append($0) })) {
                XCTAssertEqual($0 as? Failure, .write)
            }
            XCTAssertEqual(scheduled, enabled ? [7] : [])
        }
        XCTAssertThrowsError(try owner.writeLine(bytes, shutdownOnFailure: true, hasProcess: { false }, generation: { XCTFail(); return 0 },
            write: { _ in XCTFail() }, scheduleShutdown: { _ in XCTFail() })) { XCTAssertEqual($0 as? ClaudeNativeClientError, .processNotRunning) }
        try owner.writeLine(bytes, shutdownOnFailure: true, hasProcess: { true }, generation: { 1 }, write: { XCTAssertEqual($0, bytes) }, scheduleShutdown: { _ in XCTFail() })
    }
    func testWriteFailureShutdownOnlyTargetsStillOwnedLiveConnection() async {
        for state in 0..<3 {
            var shutdowns = 0
            await ClaudeNativeClientLifecycle().shutdownAfterWriteFailure(generation: 1,
                currentGeneration: { state == 0 ? 2 : 1 }, hasProcess: { state != 1 }, shutdown: { shutdowns += 1 })
            XCTAssertEqual(shutdowns, state == 2 ? 1 : 0)
        }
    }
}
