import XCTest
import Synchronization
@_spi(Testing) import AgentClaudeClient
import ClaudeRuntimeKit

@MainActor
final class ClaudeNativeClientLifecycleTests: XCTestCase {
    private enum Failure: Error, Equatable { case start, fresh }
    private final class Recorder: Sendable {
        private let storage = Mutex<[String]>([])
        func add(_ value: String) { storage.withLock { $0.append(value) } }
        var values: [String] { storage.withLock { $0 } }
    }
    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        func wait() async { entered = true; if released { return }; await withCheckedContinuation { waiter = $0 } }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }
    private func preparer(_ record: Recorder, url: URL? = URL(fileURLWithPath: "/host/config.json"), available: Bool = true) -> ClaudeNativeRuntimePreparer {
        .init(isMCPServerRunning: { record.add("available"); return available },
              prepareConfigFile: { record.add("config"); return url }, cleanupConfigFile: { _ in record.add("cleanup") })
    }
    private func shutdownActions(_ record: Recorder) -> ClaudeNativeClientLifecycle.ShutdownActions {
        .init(prepare: { record.add("prepare-shutdown") }, teardownTransport: { record.add("teardown") },
              retireEpoch: { record.add("retire") }, finish: { record.add("finish") })
    }
    func testPreparedConfigurationIsReusedAndShutdownKeepsItsOrdering() async throws {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let ports = preparer(record)
        try await owner.prepareRuntime(preparer: ports, unavailable: { Failure.start })
        try await owner.prepareRuntime(preparer: ports, unavailable: { Failure.start })
        XCTAssertEqual(record.values, ["available", "config"])
        await owner.shutdown(actions: shutdownActions(record), preparer: ports)
        XCTAssertEqual(record.values, ["available", "config", "prepare-shutdown", "teardown", "retire", "cleanup", "finish"])
        XCTAssertNil(owner.configURL); XCTAssertTrue(owner.isShuttingDown)
        await owner.shutdown(actions: shutdownActions(record), preparer: ports)
        XCTAssertEqual(record.values.filter { $0 == "finish" }.count, 1)
        owner.beginStart()
        try await owner.prepareRuntime(preparer: ports, unavailable: { Failure.start })
        XCTAssertFalse(owner.isShuttingDown); XCTAssertNotNil(owner.configURL)
    }
    func testUnavailableRuntimeDoesNotPrepareAndNilConfigurationDoesNotBecomeACacheHit() async throws {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder()
        do { try await owner.prepareRuntime(preparer: preparer(record, available: false), unavailable: { Failure.start }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .start) }
        XCTAssertEqual(record.values, ["available"])
        let ports = preparer(record, url: nil)
        try await owner.prepareRuntime(preparer: ports, unavailable: { Failure.start })
        try await owner.prepareRuntime(preparer: ports, unavailable: { Failure.start })
        XCTAssertEqual(record.values.filter { $0 == "config" }.count, 2)
    }
    func testReadyClientFastPathDoesNotResetShutdownOrPrepareAnything() async throws {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder()
        await owner.shutdown(actions: shutdownActions(record), preparer: preparer(record))
        let result = try await owner.startOrResume(actions: .init(isReady: { true }, reference: { "existing" },
            ensureEvents: { XCTFail() }, observeStart: { XCTFail() }, prepare: { XCTFail() }, spawn: { XCTFail() },
            initialize: { XCTFail() }, hasProcess: { false }, shutdown: { XCTFail() }))
        XCTAssertEqual(result, "existing"); XCTAssertTrue(owner.isShuttingDown)
    }
    func testStartupPreservesOrderAndReturnsReferenceOnlyAfterInitialization() async throws {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder()
        let result = try await owner.startOrResume(actions: .init(isReady: { false }, reference: { record.add("ref"); return "ready" },
            ensureEvents: { record.add("events") }, observeStart: { record.add("start") }, prepare: { record.add("prepare") },
            spawn: { record.add("spawn") }, initialize: { record.add("init") }, hasProcess: { true }, shutdown: { record.add("shutdown") }))
        XCTAssertEqual(result, "ready"); XCTAssertEqual(record.values, ["events", "start", "prepare", "spawn", "init", "ref"])
    }
    func testStartupFailureCleansOnlyWhenThereIsAnOwnedResource() async {
        for hasConfig in [false, true] {
            let owner = ClaudeNativeClientLifecycle(); let record = Recorder()
            if hasConfig { owner.setConfigURLForTesting(URL(fileURLWithPath: "/host/config")) }
            do { _ = try await owner.startOrResume(actions: .init(isReady: { false }, reference: { "ref" }, ensureEvents: {}, observeStart: {},
                prepare: { throw Failure.start }, spawn: { XCTFail() }, initialize: { XCTFail() }, hasProcess: { false }, shutdown: { record.add("cleanup") })); XCTFail() }
            catch { XCTAssertEqual(error as? Failure, .start) }
            XCTAssertEqual(record.values, hasConfig ? ["cleanup"] : [])
        }
    }
    func testShutdownReentrancyReturnsWithoutRepeatingEffectsAndCleanupRunsAfterRetirement() async {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let gate = Gate()
        owner.setConfigURLForTesting(URL(fileURLWithPath: "/host/config"))
        let actions = ClaudeNativeClientLifecycle.ShutdownActions(prepare: { record.add("prepare") },
            teardownTransport: { await gate.wait(); record.add("teardown") }, retireEpoch: { record.add("retire") }, finish: { record.add("finish") })
        let first = Task { await owner.shutdown(actions: actions, preparer: preparer(record)) }
        while !(await gate.entered) { await Task.yield() }
        await owner.shutdown(actions: shutdownActions(record), preparer: preparer(record))
        XCTAssertEqual(record.values, ["prepare"])
        await gate.release(); await first.value
        XCTAssertEqual(record.values, ["prepare", "teardown", "retire", "cleanup", "finish"])
    }
    func testConcurrentTeardownSharesInvalidationAndWaitsForTheSameCleanup() async {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let gate = Gate()
        let first = Task { await owner.tearDownTransport(invalidate: { record.add("invalidate"); return nil }, clearRegistration: { record.add("clear"); await gate.wait() }) }
        while !(await gate.entered) { await Task.yield() }
        let second = Task { await owner.tearDownTransport(invalidate: { record.add("duplicate"); return nil }, clearRegistration: { record.add("duplicate-clear") }) }
        await Task.yield(); XCTAssertEqual(record.values, ["invalidate", "clear"])
        await gate.release(); await first.value; await second.value
        XCTAssertEqual(record.values, ["invalidate", "clear"])
    }
    func testRegistrationIsClearedOnceAndDisabledClientsDoNotRegister() async {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let run = UUID()
        let registrar = ClaudeExpectedAgentPIDRegistrar(register: { pid, _, _ in record.add("register-\(pid)") }, clear: { pid, _, _ in record.add("clear-\(pid)") })
        await owner.registerPID(10, clientName: nil, runID: run, registrar: registrar, generation: { 1 }, registered: { XCTFail() })
        await owner.registerPID(10, clientName: "host", runID: run, registrar: registrar, generation: { 1 }, registered: { record.add("registered") })
        await owner.clearPID(clientName: "host", runID: run, registrar: registrar, cleared: { record.add("cleared") })
        await owner.clearPID(clientName: "host", runID: run, registrar: registrar, cleared: { XCTFail() })
        XCTAssertEqual(record.values, ["register-10", "registered", "clear-10", "cleared"])
    }
    func testLateRegistrationIsRejectedAfterGenerationReplacementOrShutdown() async {
        for shutdown in [false, true] {
            let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let gate = Gate(); var generation: UInt64 = 1
            let registrar = ClaudeExpectedAgentPIDRegistrar(register: { _, _, _ in await gate.wait() }, clear: { _, _, _ in record.add("clear") })
            let task = Task { await owner.registerPID(10, clientName: "host", runID: UUID(), registrar: registrar, generation: { generation }, registered: { XCTFail() }) }
            while !(await gate.entered) { await Task.yield() }
            if shutdown { await owner.shutdown(actions: .init(prepare: {}, teardownTransport: {}, retireEpoch: {}, finish: {}), preparer: preparer(record)) }
            else { generation = 2 }
            await gate.release(); await task.value
            XCTAssertEqual(record.values, ["clear"])
        }
    }
    func testInterruptTargetsCapturedHeadDespiteTurnChangeDuringACK() async {
        let owner = ClaudeNativeClientLifecycle(); let first = ClaudeTurnGeneration(value: 1); let second = ClaudeTurnGeneration(value: 2); var current = first
        var observed: ClaudeTurnGeneration?
        let outcome = await owner.interrupt(hasProcess: { true }, hasTurn: { true }, headGeneration: { current }, send: { current = second }, observe: { observation in
            if case .acknowledged(let target) = observation { observed = target }
        })
        XCTAssertEqual(outcome, .acknowledged); XCTAssertEqual(observed, first)
    }
    func testInterruptNoTurnTimeoutAndFailureDoNotInventAcknowledgements() async {
        let owner = ClaudeNativeClientLifecycle()
        let absent = await owner.interrupt(hasProcess: { false }, hasTurn: { true }, headGeneration: { nil }, send: { XCTFail() }, observe: { _ in XCTFail() })
        XCTAssertEqual(absent, .failed)
        let idle = await owner.interrupt(hasProcess: { true }, hasTurn: { false }, headGeneration: { nil }, send: { XCTFail() }, observe: { _ in XCTFail() })
        XCTAssertEqual(idle, .noTurnInFlight)
        for timedOut in [false, true] {
            let result = await owner.interrupt(hasProcess: { true }, hasTurn: { true }, headGeneration: { nil }, send: {
                if timedOut { throw ClaudeNativeClientError.controlRequestTimedOut(requestID: "id") }; throw Failure.start
            }, observe: { observation in if case .acknowledged = observation { XCTFail() } })
            XCTAssertEqual(result, timedOut ? .timedOut : .failed)
        }
    }
    func testRecoveryPreservesHandoffShutdownDiscardAndFreshOrdering() async throws {
        var order: [String] = []
        let result = try await ClaudeNativeResumeRecovery.start(existingSessionID: "resume", actions: .init(
            startInitial: { () async throws -> String in order.append("initial"); throw ClaudeNativeClientError.initializationFailed("failed") },
            stageHandoff: { order.append("handoff") }, shutdownInitial: { order.append("shutdown") },
            discardInitial: { order.append("discard") }, startFresh: { order.append("fresh"); return "fresh-session" }))
        XCTAssertEqual(result, "fresh-session"); XCTAssertEqual(order, ["initial", "handoff", "shutdown", "discard", "fresh"])
    }
    func testRecoverySuccessAndPolicyFailureDoNotTouchHostStateAndFreshFailureIsNotRetried() async throws {
        let good = try await ClaudeNativeResumeRecovery.start(existingSessionID: "resume", actions: .init(startInitial: { "resumed" }, stageHandoff: { XCTFail() }, shutdownInitial: { XCTFail() }, discardInitial: { XCTFail() }, startFresh: { XCTFail(); return "bad" }))
        XCTAssertEqual(good, "resumed")
        var retried = 0
        for policy in [false, true] {
            do { _ = try await ClaudeNativeResumeRecovery.start(existingSessionID: "resume", actions: .init(startInitial: { () async throws -> String in
                if policy { throw ClaudeNativeClientError.admissionEnvelopeMissing }; throw ClaudeNativeClientError.processNotRunning
            }, stageHandoff: {}, shutdownInitial: {}, discardInitial: {}, startFresh: { () async throws -> String in retried += 1; throw Failure.fresh })); XCTFail() }
            catch { if policy { XCTAssertEqual(error as? ClaudeNativeClientError, .admissionEnvelopeMissing) } else { XCTAssertEqual(error as? Failure, .fresh) } }
        }
        XCTAssertEqual(retried, 1)
    }
    func testProtocolFailureEffectsPrecedeAwaitedShutdownAndLateFailuresAreInert() async {
        let owner = ClaudeNativeClientLifecycle(); let record = Recorder(); let gate = Gate()
        let first = Task { await owner.failProtocol(fail: { record.add("failure") }, shutdown: {
            await owner.shutdown(actions: .init(prepare: { record.add("prepare") }, teardownTransport: { await gate.wait() }, retireEpoch: { record.add("retire") }, finish: { record.add("finish") }), preparer: preparer(record))
        }) }
        while !(await gate.entered) { await Task.yield() }
        await owner.failProtocol(fail: { XCTFail("late failure") }, shutdown: { XCTFail("duplicate shutdown") })
        XCTAssertEqual(record.values, ["failure", "prepare"])
        await gate.release(); await first.value
        XCTAssertEqual(record.values, ["failure", "prepare", "retire", "finish"])
    }

}
