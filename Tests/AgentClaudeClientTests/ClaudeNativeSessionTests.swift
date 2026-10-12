import Foundation
import XCTest
import Synchronization
@_spi(Testing) import AgentClaudeClient
import AgentClaudeContent
import AgentClaudeProtocol
import AgentClaudeControl
import AgentClaudePermissions
import AgentClaudeExecution
import AgentClaudeSession
import AgentClaudeEvents
import AgentClaudeCapabilities
import AgentClaudeLaunch
import AgentRuntimeKit
import ClaudeRuntimeKit

@MainActor
final class ClaudeNativeSessionTests: XCTestCase {
    private enum Failure: Error, Equatable { case denied, write, readers, initial, admit }
    private enum Effort: String, Sendable { case high }
    private typealias Launch = ClaudeAdmittedLaunch<String, Effort, String>
    private final class Recorder: Sendable {
        private let storage = Mutex<[String]>([])
        func add(_ value: String) { storage.withLock { $0.append(value) } }
        var values: [String] { storage.withLock { $0 } }
    }
    private actor Gate {
        private let pair = AsyncStream<Void>.makeStream()
        var entered: AsyncStream<Void> { pair.stream }
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0; pair.continuation.yield(()); pair.continuation.finish() } }
        func release() { waiter?.resume(); waiter = nil }
    }
    @MainActor private final class Host {
        let session: ClaudeNativeSession
        init() { session = .init(requestIDPrefix: "host-", authority: .normalized, translatorPolicy: .init(isExternallyTrackedTool: { _ in false }, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }), controlSleep: { _ in }) }
        func expire(_ ticket: ClaudeNativeProtocolSession.ControlTicket) { session.expire(ticket) }
    }
    private func owner(idleSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> ClaudeNativeSession {
        .init(requestIDPrefix: "host-", authority: .normalized, translatorPolicy: .init(isExternallyTrackedTool: { _ in false }, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }), idleSleep: idleSleep)
    }
    private func preparer(_ record: Recorder) -> ClaudeNativeRuntimePreparer {
        .init(isMCPServerRunning: { record.add("mcp"); return true }, prepareConfigFile: { record.add("config"); return URL(fileURLWithPath: "/host/config.json") }, cleanupConfigFile: { _ in record.add("cleanup") })
    }
    private func launch(settings: ClaudeProtocolJSONObject? = nil) -> Launch {
        let key = ClaudeLaunchProfileKey(input: .init(commandNameClass: .explicitPath, resumeRequested: false, modelRoute: .defaultRoute, effortClass: .defaultEffort, permissionModeClass: .requireApproval, backendClass: .standardClaude, authenticationModeClass: .anthropicAPIKey, workingDirectoryClass: .disposableOutsideRepo, mcpConfigPresent: true, mcpStrictMode: true, disallowedToolsDigest: .init(toolNames: [])))
        let coordinator = ClaudeAdmissionCoordinator(manifest: .empty)
        return .init(plan: .init(resolvedCommand: "/host/claude", arguments: ["-p"], environment: ["HOST": "fixture"], workingDirectory: "/host/root", launchEnvironment: "fixture", flagSettingsRequest: settings), runtimeResolution: .unresolvable(.missingPath), launchProfileKey: key, prelaunchEvaluation: coordinator.evaluatePrelaunch(.unresolvable(.missingPath), stage: .observeOnly), cycleGuard: .notEvaluatedObserveOnly, manifestSource: "fixture", coordinator: coordinator, stage: .observeOnly, effectiveKnobs: .init(existingSessionID: nil, model: nil, effortLevel: .high, permissionMode: "plan"))
    }
    private func startTransport(_ s: ClaudeNativeSession, launch: Launch, observe: @escaping ClaudeNativeExecution.Observer = { _ in }, order: Recorder = Recorder()) async throws {
        try await s.startTransport(hasProcess: { false }, resetAdmission: { order.add("reset") }, admit: { order.add("admit"); return launch }, adopt: { XCTAssertEqual($0.plan.flagSettingsRequest, launch.plan.flagSettingsRequest); order.add("adopt") }, spawn: { XCTAssertEqual($0.plan.resolvedCommand, launch.plan.resolvedCommand); order.add("spawn"); return 7 }, startReaders: { order.add("readers") }, invalidateReaders: { XCTFail() }, registerPID: { _ in order.add("register") }, observe: observe)
    }
    private func initialize(_ s: ClaudeNativeSession, rpc: @escaping ClaudeSessionInitialization.RPC = { _, _ in try .init(object: [:]) }, permission: ClaudeProtocolJSONObject? = nil, admit: @escaping (ClaudeProtocolJSONObject, ClaudePermissionModeRoundTrip) async throws -> Void = { _, _ in }, observe: @escaping ClaudeNativeExecution.Observer = { _ in }) async throws {
        try await s.initialize(systemPromptOverride: nil, timeoutSeconds: nil, rpc: rpc, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, permissionModeRequest: { permission }, observePermissionMode: { _ in }, admit: admit, observe: observe)
    }
    private func shutdown(_ s: ClaudeNativeSession, record: Recorder = Recorder(), observe: @escaping ClaudeNativeExecution.Observer = { _ in }) async {
        await s.shutdown(preparer: preparer(record), observeShutdown: { record.add("shutdown") }, teardownTransport: { record.add("teardown") }, retireAdmission: { record.add("retire") }, finish: { record.add("finish") }, observe: observe)
    }
    private func routing(_ s: ClaudeNativeSession, presented: @escaping (AgentApprovalRequest) -> Void = { _ in }) -> ClaudeNativeProtocolSession.Routing<Void> {
        .init(stream: { try? s.consume($0, observe: { _ in }) }, policy: { request in
            .init(.present(ClaudePermissionPresentation.make(from: request, context: .init(threadID: "host", turnID: "run", workspacePath: nil))))
        }, write: { _ in }, observe: { if case .permission(_, .requested(let value, _), _) = $0 { presented(value) } }, approvalCancelled: { _ in }, requestFailed: { _, _, _ in XCTFail() })
    }
    private func permission(_ id: String = "ask") throws -> ClaudeNativeProtocolCodec.InboundMessage {
        .controlRequest(.init(requestID: id, request: try .init(object: ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "fixture"]]), subtype: "can_use_tool"))
    }
    private func state(_ value: String) throws -> ClaudeProtocolJSONObject { try .init(object: ["type": "system", "subtype": "session_state_changed", "session_state": value]) }
    private func result(_ id: String = "result") throws -> ClaudeProtocolJSONObject { try .init(object: ["type": "result", "uuid": id, "subtype": "success", "result": "done"]) }
    private func drain(_ s: ClaudeNativeSession) async -> [String] {
        var labels: [String] = []
        for await event in s.events {
            switch event { case .error: labels.append("error"); case .turnCompleted(_, let status): labels.append("complete:\(status)"); default: break }
        }
        return labels
    }
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        XCTAssertTrue(condition())
    }
    func testStartupReturnsReferenceAfterPreparationSpawnAndInitialization() async throws {
        let s = owner(); let order = Recorder()
        let ref = try await s.startOrResume(hasProcess: { true }, observeStart: { order.add("start") }, prepare: { order.add("prepare") }, spawn: { order.add("spawn") }, initialize: { order.add("initialize"); try s.consume(.init(object: ["type": "system", "subtype": "init", "session_id": " raw "]), observe: { _ in }) }, shutdown: { XCTFail() })
        XCTAssertEqual(ref.sessionID, "raw"); XCTAssertEqual(order.values, ["start", "prepare", "spawn", "initialize"])
    }
    func testReadyStartupDoesNotRepeatHostEffects() async throws {
        let s = owner(); try await initialize(s)
        _ = try await s.startOrResume(hasProcess: { true }, observeStart: { XCTFail() }, prepare: { XCTFail() }, spawn: { XCTFail() }, initialize: { XCTFail() }, shutdown: { XCTFail() })
        XCTAssertTrue(s.isInitialized)
    }
    func testStartupFailureAwaitsCleanupOfOwnedConfiguration() async throws {
        let s = owner(); let record = Recorder()
        try await s.prepareRuntime(preparer: preparer(record), unavailable: { Failure.initial })
        do { _ = try await s.startOrResume(hasProcess: { false }, observeStart: {}, prepare: {}, spawn: { throw Failure.initial }, initialize: { XCTFail() }, shutdown: { await self.shutdown(s, record: record) }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .initial) }
        XCTAssertEqual(record.values, ["mcp", "config", "shutdown", "teardown", "retire", "cleanup", "finish"]); XCTAssertNil(s.configURL)
    }
    func testAdmittedLaunchOwnsSettingsAndTransportEpochBeforeReaders() async throws {
        let s = owner(); let order = Recorder(); let settings = try ClaudeNativeSessionContract.flagSettingsRequest(model: "raw", effortLevel: nil, defaultModelIdentifier: "default")
        try await startTransport(s, launch: launch(settings: settings), observe: { if case .transportStarted = $0 { order.add("epoch") } }, order: order)
        let rpcOrder = Recorder()
        try await initialize(s, rpc: { request, _ in let subtype = try request.dictionary()["subtype"] as? String; rpcOrder.add(subtype ?? "nil"); if subtype == "apply_flag_settings" { XCTAssertEqual(request, settings) }; return try .init(object: [:]) })
        XCTAssertEqual(order.values, ["reset", "admit", "adopt", "spawn", "epoch", "readers", "register"])
        XCTAssertEqual(rpcOrder.values, ["initialize", "apply_flag_settings"])
    }
    func testAdmissionRefusalPreventsAdoptionSpawnReadersAndRegistration() async {
        let s = owner()
        do { try await s.startTransport(hasProcess: { false }, resetAdmission: {}, admit: { () async throws -> Launch in throw Failure.admit }, adopt: { _ in XCTFail() }, spawn: { _ in XCTFail(); return 0 }, startReaders: { XCTFail() }, invalidateReaders: { XCTFail() }, registerPID: { _ in XCTFail() }, observe: { _ in XCTFail() }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .admit) }
    }
    func testReaderFailureAwaitsCleanupAndDoesNotRegisterPID() async {
        let s = owner(); let order = Recorder(); let value = launch()
        do { try await s.startTransport(hasProcess: { false }, resetAdmission: {}, admit: { value }, adopt: { _ in }, spawn: { _ in 7 }, startReaders: { throw Failure.readers }, invalidateReaders: { order.add("cleanup") }, registerPID: { _ in XCTFail() }, observe: { _ in }); XCTFail() }
        catch { guard case .initializationFailed = error as? ClaudeNativeClientError else { return XCTFail("\(error)") } }
        XCTAssertEqual(order.values, ["cleanup"])
    }
    func testInitializationCarriesConfirmedModeToAdmissionBeforeReadiness() async throws {
        let s = owner(); let record = Recorder(); let response = try ClaudeProtocolJSONObject(object: ["models": ["raw"]])
        let permission = try ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: "plan")
        try await s.initialize(systemPromptOverride: "", timeoutSeconds: 3, rpc: { request, timeout in
            let kind = try request.dictionary()["subtype"] as? String; record.add(kind ?? "nil")
            if kind == "initialize" { XCTAssertEqual(timeout, 3); XCTAssertEqual(try request.dictionary()["systemPrompt"] as? String, ""); return response }
            XCTAssertEqual(kind, "set_permission_mode"); XCTAssertNil(timeout); return try .init(object: ["mode": "plan"])
        }, onResponse: { XCTAssertEqual($0, response); record.add("response") }, onSnapshot: { _, _ in record.add("snapshot") }, observeSettings: { _ in }, permissionModeRequest: { permission }, observePermissionMode: { value in XCTAssertEqual(value.roundTrip, .confirmed(mode: "plan")); record.add("permission") }, admit: { value, roundTrip in
            XCTAssertEqual(value, response); XCTAssertEqual(roundTrip, .confirmed(mode: "plan")); XCTAssertFalse(s.isInitialized); record.add("admit")
        }, observe: { _ in })
        XCTAssertEqual(record.values, ["initialize", "response", "snapshot", "set_permission_mode", "permission", "admit"]); XCTAssertTrue(s.isInitialized)
    }
    func testMissingPermissionRequestIsNotAttemptedAndAdmissionFailurePreventsReadiness() async throws {
        let s = owner()
        do { try await initialize(s, admit: { _, mode in XCTAssertEqual(mode, .notAttempted); throw Failure.admit }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .admit) }
        XCTAssertFalse(s.isInitialized)
    }
    func testLiveSettingsAdmissionPrecedesResolutionAndFailureLeavesSettingsUntouched() async throws {
        let s = owner(); let record = Recorder()
        let absent = try await s.applyLiveSettings(isProcessAvailable: { false }, admit: { XCTFail() }, resolve: { XCTFail(); return nil }, rpc: { _, _ in XCTFail(); return try .init(object: [:]) }, observeSettings: { _ in XCTFail() })
        XCTAssertEqual(absent, .noProcess)
        do { _ = try await s.applyLiveSettings(isProcessAvailable: { true }, admit: { record.add("admit"); throw Failure.denied }, resolve: { XCTFail(); return nil }, rpc: { _, _ in XCTFail(); return try .init(object: [:]) }, observeSettings: { _ in XCTFail() }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .denied) }
        XCTAssertEqual(record.values, ["admit"])
    }
    func testPendingLiveSettingsAreAppliedDuringInitialization() async throws {
        let s = owner(); let settings = try ClaudeNativeSessionContract.flagSettingsRequest(model: "raw", effortLevel: nil, defaultModelIdentifier: "default")
        let outcome = try await s.applyLiveSettings(isProcessAvailable: { true }, admit: {}, resolve: { settings }, rpc: { _, _ in XCTFail(); return try .init(object: [:]) }, observeSettings: { _ in })
        XCTAssertEqual(outcome, .pendingInitialization)
        let record = Recorder()
        try await initialize(s, rpc: { request, _ in record.add((try request.dictionary()["subtype"] as? String) ?? "nil"); return try .init(object: [:]) })
        XCTAssertEqual(record.values, ["initialize", "apply_flag_settings"])
    }
    func testUserWriteBeforeTurnAndResultCompletesExactlyOnce() async throws {
        let s = owner(); try s.consume(.init(object: ["type": "system", "subtype": "init", "session_id": "host-session"]), observe: { _ in })
        let id = try s.sendUserMessage("hello", isAvailable: { true }, write: { value in
            XCTAssertFalse(s.hasOpenTurns); let object = try JSONSerialization.jsonObject(with: value) as? [String: Any]
            XCTAssertEqual(object?["session_id"] as? String, "host-session")
        })
        let generation = s.generation(for: id)
        try s.consume(result(), observe: { _ in }); try s.consume(result(), observe: { _ in })
        XCTAssertEqual(s.completions.count, 1); XCTAssertEqual(s.completions.first?.turn, generation)
        await self.shutdown(s); let events = await drain(s); XCTAssertEqual(events, ["complete:completed"])
    }
    func testFailedOrUnavailableWritesDoNotOpenTurns() {
        let s = owner()
        XCTAssertThrowsError(try s.sendUserMessage("hello", isAvailable: { true }, write: { _ in throw Failure.write }))
        XCTAssertThrowsError(try s.sendUserMessage("hello", isAvailable: { false }, write: { _ in XCTFail() }))
        XCTAssertFalse(s.hasOpenTurns)
    }
    func testInterruptTargetsCapturedTurnAndPreservesObservationOrder() async throws {
        let s = owner(); let first = s.openTurn(); let record = Recorder()
        let outcome = await s.interrupt(hasProcess: { true }, send: { _ = s.openTurn() }, beforeAcknowledged: { record.add("before") }, observe: { value in
            guard case .acknowledged(let target) = value else { return XCTFail() }
            XCTAssertEqual(target, s.generation(for: first)); XCTAssertGreaterThan(s.observedInputCount, 0); record.add("observed")
        })
        XCTAssertEqual(outcome, .acknowledged); XCTAssertEqual(record.values, ["before", "observed"])
        try s.consume(result("first"), observe: { _ in }); try s.consume(result("second"), observe: { _ in })
        await self.shutdown(s); let events = await drain(s); XCTAssertEqual(events, ["complete:cancelled", "complete:completed"])
    }
    func testInterruptTimeoutAndNoTurnCannotCreateAcknowledgements() async {
        let s = owner()
        let idle = await s.interrupt(hasProcess: { true }, send: { XCTFail() }, beforeAcknowledged: { XCTFail() }, observe: { _ in XCTFail() })
        XCTAssertEqual(idle, .noTurnInFlight)
        _ = s.openTurn()
        let timed = await s.interrupt(hasProcess: { true }, send: { throw ClaudeNativeClientError.controlRequestTimedOut(requestID: "fixture") }, beforeAcknowledged: { XCTFail() }, observe: { guard case .timedOut = $0 else { return XCTFail() } })
        XCTAssertEqual(timed, .timedOut)
    }
    func testPermissionDecisionRetiresAskAndShutdownRejectsLateReplies() async throws {
        let s = owner(); var values: [AgentApprovalRequest] = []; s.route(try permission(), routing: routing(s, presented: { values.append($0) }))
        XCTAssertEqual(values.count, 1); XCTAssertEqual(s.pendingPermissionRequestIDs, ["ask"])
        var replied = false
        await s.respondPermission(id: "ask", decision: .accept, write: { _ in replied = true }, observe: { _ in }, failure: { _ in XCTFail() })
        XCTAssertTrue(replied); XCTAssertTrue(s.pendingPermissionRequestIDs.isEmpty)
        s.route(try permission("later"), routing: routing(s)); await self.shutdown(s)
        await s.respondPermission(id: "later", decision: .accept, write: { _ in XCTFail() }, observe: { _ in XCTFail() }, failure: { _ in XCTFail() })
        XCTAssertTrue(s.pendingPermissionRequestIDs.isEmpty)
    }
    func testControlRequestsShareScopeAndShutdownFailsPendingContinuation() async throws {
        let s = owner(); let task = Task { try await s.request(.init(object: ["subtype": "fixture"]), timeoutSeconds: nil, onExpiry: { _ in }, isAvailable: { true }, observe: { value, response in XCTAssertTrue(value.requestID.hasPrefix("host-")); XCTAssertTrue(response) }, write: { _ in }) }
        await wait { !s.pendingControlRequestIDs.isEmpty }; await self.shutdown(s)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? ClaudeNativeClientError, .processNotRunning) }
        XCTAssertTrue(s.pendingControlRequestIDs.isEmpty)
    }
    func testControlDeadlineDeliversToHostActorThroughSessionOwner() async throws {
        let host = Host()
        do { _ = try await host.session.request(.init(object: ["subtype": "fixture"]), timeoutSeconds: 1, onExpiry: { [weak host] value in await host?.expire(value) }, isAvailable: { true }, observe: { _, _ in }, write: { _ in }); XCTFail() }
        catch { guard case .controlRequestTimedOut = error as? ClaudeNativeClientError else { return XCTFail("\(error)") } }
        XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty)
    }
    func testNewTransportEpochRetiresOldPermissionsWithoutDroppingHostPolicy() async throws {
        let s = owner(); s.route(try permission(), routing: routing(s)); XCTAssertEqual(s.pendingPermissionRequestIDs, ["ask"])
        try await startTransport(s, launch: launch()); XCTAssertTrue(s.pendingPermissionRequestIDs.isEmpty)
        s.route(try permission(), routing: routing(s)); XCTAssertEqual(s.pendingPermissionRequestIDs, ["ask"])
    }
    func testShutdownDrainsDeferredOutcomeBeforeClearingAndAbandonsOtherTurns() async throws {
        let s = owner(); _ = s.openTurn(); try s.consume(state("running"), observe: { _ in }); try s.consume(result(), observe: { _ in }); _ = s.openTurn()
        let order = Recorder(); await self.shutdown(s, record: order, observe: { if case .willEmit(.turnCompleted) = $0 { order.add("complete") } })
        XCTAssertEqual(order.values, ["shutdown", "complete", "teardown", "retire", "finish"])
        XCTAssertEqual(s.pendingTurnCount, 0); let events = await drain(s); XCTAssertEqual(events, ["complete:completed"])
    }
    func testShutdownReentrancyDoesNotRepeatEffects() async throws {
        let s = owner(); let gate = Gate(); let entered = await gate.entered; let order = Recorder()
        let first = Task { await s.shutdown(preparer: preparer(order), observeShutdown: { order.add("shutdown") }, teardownTransport: { await gate.wait() }, retireAdmission: { order.add("retire") }, finish: { order.add("finish") }, observe: { _ in }) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next(); await self.shutdown(s, record: order)
        XCTAssertEqual(order.values, ["shutdown"]); await gate.release(); await first.value
        XCTAssertEqual(order.values, ["shutdown", "retire", "finish"])
    }
    func testEOFErrorPrecedesDeferredAndFailedCompletionsAndRetiresAsks() async throws {
        let s = owner(); _ = s.openTurn(); try s.consume(state("running"), observe: { _ in }); try s.consume(result(), observe: { _ in }); _ = s.openTurn()
        s.route(try permission(), routing: routing(s))
        await s.handleEOF(generation: 1, currentGeneration: { 1 }, hasProcess: { true }, observeEOF: {}, flush: { nil }, failProtocol: { _ in XCTFail() }, teardownTransport: {}, unexpectedExitMessage: "host-exit", observe: { _ in })
        let events = await drain(s); XCTAssertEqual(events, ["error", "complete:completed", "complete:failed"])
        XCTAssertTrue(s.pendingPermissionRequestIDs.isEmpty); XCTAssertFalse(s.isInitialized)
    }
    func testEOFStaleGenerationCannotFlushOrTearDownReplacement() async {
        let s = owner()
        await s.handleEOF(generation: 1, currentGeneration: { 2 }, hasProcess: { true }, observeEOF: { XCTFail() }, flush: { XCTFail(); return nil }, failProtocol: { _ in XCTFail() }, teardownTransport: { XCTFail() }, unexpectedExitMessage: "host-exit", observe: { _ in XCTFail() })
    }
    func testEOFFlushFailureUsesFailurePathAndSuppressesDuplicateClose() async throws {
        let s = owner(); _ = s.openTurn(); let order = Recorder()
        await s.handleEOF(generation: 1, currentGeneration: { 1 }, hasProcess: { true }, observeEOF: {}, flush: { "decode" }, failProtocol: { message in
            await s.failProtocol(message: message, observeFailure: { order.add("failure") }, observe: { _ in }, shutdown: { await self.shutdown(s, record: order) })
        }, teardownTransport: { XCTFail("close after shutdown") }, unexpectedExitMessage: "host-exit", observe: { _ in XCTFail() })
        let events = await drain(s); XCTAssertEqual(events, ["error", "complete:failed"]); XCTAssertEqual(order.values, ["failure", "shutdown", "teardown", "retire", "finish"])
    }
    func testProtocolFailureOverridesDeferredResultAndAwaitsShutdown() async throws {
        let s = owner(); _ = s.openTurn(); try s.consume(state("running"), observe: { _ in }); try s.consume(result(), observe: { _ in })
        let order = Recorder()
        await s.failProtocol(message: "host-failure", observeFailure: { order.add("failure") }, observe: { if case .willEmit(.turnCompleted) = $0 { order.add("complete") } }, shutdown: { await self.shutdown(s, record: order) })
        let events = await drain(s); XCTAssertEqual(events, ["error", "complete:failed"]); XCTAssertEqual(order.values, ["failure", "complete", "shutdown", "teardown", "retire", "finish"])
        await s.failProtocol(message: "late", observeFailure: { XCTFail() }, observe: { _ in XCTFail() }, shutdown: { XCTFail() })
    }
    func testWriteFailurePreservesErrorAndCapturesConnectionGeneration() async {
        let s = owner(); var generation: UInt64 = 1; var captured: UInt64?
        XCTAssertThrowsError(try s.writeLine(Data(), shutdownOnFailure: true, hasProcess: { true }, generation: { generation }, write: { _ in generation = 2; throw Failure.write }, scheduleShutdown: { captured = $0 })) { XCTAssertEqual($0 as? Failure, .write) }
        XCTAssertEqual(captured, 1)
        await s.shutdownAfterWriteFailure(generation: 1, currentGeneration: { generation }, hasProcess: { true }, shutdown: { XCTFail() })
    }
    func testMatchedControlReplyCompletesOnlyOnceThroughSessionRouting() async throws {
        let s = owner(); let task = Task { try await s.request(.init(object: ["subtype": "fixture"]), timeoutSeconds: nil, onExpiry: { _ in }, isAvailable: { true }, observe: { _, _ in }, write: { _ in }) }
        await wait { !s.pendingControlRequestIDs.isEmpty }; let id = try XCTUnwrap(s.pendingControlRequestIDs.first)
        let object = try ClaudeProtocolJSONObject(object: ["type": "control_response", "response": ["request_id": id, "subtype": "success", "response": ["ok": true]]])
        let inbound = try XCTUnwrap(ClaudeNativeProtocolCodec.decodeLine(object.data))
        s.route(inbound, routing: routing(s)); s.route(inbound, routing: routing(s))
        let result = try await task.value; XCTAssertEqual(try result.dictionary()["ok"] as? Bool, true)
        XCTAssertTrue(s.pendingControlRequestIDs.isEmpty)
    }
    func testShutdownDuringAdmissionPreventsReadinessAfterSuspendedCallbackReturns() async throws {
        let s = owner(); let gate = Gate(); let entered = await gate.entered
        let task = Task { try await initialize(s, admit: { _, _ in await gate.wait() }) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next(); await self.shutdown(s); await gate.release()
        do { try await task.value; XCTFail("retired initialization") } catch { XCTAssertEqual(error as? ClaudeNativeClientError, .processNotRunning) }
        XCTAssertFalse(s.isInitialized)
    }
    func testEOFReplacementDuringTeardownCannotRetireNewInitialization() async throws {
        let s = owner(); _ = s.openTurn(); var generation: UInt64 = 1
        await s.handleEOF(generation: 1, currentGeneration: { generation }, hasProcess: { true }, observeEOF: {}, flush: { nil }, failProtocol: { _ in XCTFail() }, teardownTransport: {
            generation = 2
            do { try await startTransport(s, launch: launch()); try await initialize(s); _ = s.openTurn() }
            catch { XCTFail("\(error)") }
        }, unexpectedExitMessage: "old-exit", observe: { _ in XCTFail("old close effects") })
        XCTAssertTrue(s.isInitialized); XCTAssertTrue(s.hasOpenTurns); XCTAssertTrue(s.completions.isEmpty)
        await self.shutdown(s)
    }
    func testIdleFallbackCompletesDeferredResultOnceThroughOwnedExecution() async throws {
        let s = owner(); _ = s.openTurn(); try s.consume(state("running"), observe: { _ in }); try s.consume(result(), observe: { _ in })
        let delivery = AsyncStream<ClaudeNativeExecution.IdleFallbackToken>.makeStream()
        s.reconcileIdleFallback(seconds: 1) { delivery.continuation.yield($0) }
        var iterator = delivery.stream.makeAsyncIterator(); let value = await iterator.next(); let token = try XCTUnwrap(value)
        var observed = 0
        s.fireIdleFallback(token, observeFallback: { observed += 1 }, observe: { _ in })
        s.fireIdleFallback(token, observeFallback: { XCTFail() }, observe: { _ in XCTFail() })
        XCTAssertEqual(observed, 1); XCTAssertFalse(s.hasDeferredOutcomes); XCTAssertEqual(s.completions.count, 1)
        await self.shutdown(s); let events = await drain(s); XCTAssertEqual(events, ["complete:completed"])
    }
    func testShutdownRetiresAlreadyDeliveredIdleFallback() async throws {
        let s = owner(); _ = s.openTurn(); try s.consume(state("running"), observe: { _ in }); try s.consume(result(), observe: { _ in })
        let delivery = AsyncStream<ClaudeNativeExecution.IdleFallbackToken>.makeStream()
        s.reconcileIdleFallback(seconds: 1) { delivery.continuation.yield($0) }
        var iterator = delivery.stream.makeAsyncIterator(); let value = await iterator.next(); let token = try XCTUnwrap(value)
        await self.shutdown(s)
        s.fireIdleFallback(token, observeFallback: { XCTFail("retired timer") }, observe: { _ in XCTFail() })
        XCTAssertEqual(s.completions.count, 1)
    }

}
