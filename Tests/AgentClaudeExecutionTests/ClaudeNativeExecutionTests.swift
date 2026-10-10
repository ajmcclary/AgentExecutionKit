import Foundation
import XCTest
import AIClientKit
import ClaudeRuntimeKit
import AgentClaudeProtocol
import AgentClaudeContent
import AgentClaudeEvents
import AgentClaudeSession
@_spi(Testing) import AgentClaudeExecution

private enum FixtureError: Error, Equatable { case unavailable, rejected }
private actor Gate {
	let entered: AsyncStream<Void>
	private let ready: AsyncStream<Void>.Continuation
	private var waiting: CheckedContinuation<Void, Never>?
	init() { let pair = AsyncStream<Void>.makeStream(); entered = pair.stream; ready = pair.continuation }
	func wait() async { await withCheckedContinuation { waiting = $0; ready.yield(()); ready.finish() } }
	func release() { let old = waiting; waiting = nil; old?.resume() }
}
@MainActor
final class ClaudeNativeExecutionTests: XCTestCase {
	private func engine(_ authority: ClaudeProjectionAuthority = .normalized) -> ClaudeNativeExecution {
		.init(authority: authority, translatorPolicy: .init(isExternallyTrackedTool: { _ in false }, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }), unavailable: { FixtureError.unavailable })
	}
	private func wire(_ text: String) throws -> ClaudeProtocolJSONObject { try .init(data: Data(text.utf8)) }
	private func result(_ verdict: String = "success", id: String = "result") throws -> ClaudeProtocolJSONObject {
		try .init(object: ["type": "result", "uuid": id, "subtype": verdict, "result": "done", "usage": ["input_tokens": 2, "output_tokens": 3]])
	}
	private func state(_ text: String) throws -> ClaudeProtocolJSONObject { try .init(object: ["type": "system", "subtype": "session_state_changed", "session_state": text]) }
	private func drain(_ stream: AsyncStream<ClaudeNativeEvent>) async -> [ClaudeNativeEvent] { var out: [ClaudeNativeEvent] = []; for await event in stream { out.append(event) }; return out }
	private func labels(_ events: [ClaudeNativeEvent]) -> [String] {
		events.map { event in
			switch event {
			case .stream(let value): return "stream:\(value.type)"
			case .runtimeInit(let value): return "init:\(value.sessionID ?? "nil"):\(value.initializeResponse != nil)"
			case .turnAggregateIdentity: return "identity"
			case .turnCompleted(_, let status): return "complete:\(status)"
			case .error: return "error"
			case .approvalRequest: return "approval"
			case .approvalCancelled: return "cancelApproval"
			}
		}
	}
	private func finish(_ owner: ClaudeNativeExecution) async -> [ClaudeNativeEvent] { owner.finishEvents(); return await drain(owner.events) }
	func testMetadataAndContentShareOrderedSystemInitDispatch() async throws {
		let e = engine(); var order: [String] = []
		try e.consume(wire(#"{"type":"system","subtype":"init","session_id":" raw ","tools":["Read"],"mcp_servers":[{"name":"host","status":"connected"}]}"#)) { observation in
			switch observation { case .willEmit(.runtimeInit): order.append("init"); case .systemInit: order.append("observed"); case .willEmit(.stream): order.append("content"); default: break }
		}
		XCTAssertEqual(order, ["init", "observed", "init", "content"])
		XCTAssertEqual(e.sessionID, "raw"); XCTAssertEqual(e.runtimeSnapshot.tools, ["Read"])
		XCTAssertEqual(e.runtimeSnapshot.serverStatus(named: "HOST"), "connected")
		let captured1 = labels(await finish(e)); XCTAssertEqual(captured1, ["init:raw:false", "init:raw:false", "stream:lifecycle"])
	}
	func testResultContentAndUsageIdentityPrecedeExactlyOnceCompletionInBothModes() async throws {
		for authority in ClaudeProjectionAuthority.allCases {
			let e = engine(authority); let turn = e.openTurn(); var stampedBeforeProjection = false
			try e.consume(result()) { if case .projection = $0 { stampedBeforeProjection = e.observedInputCount == 1 } }
			XCTAssertTrue(stampedBeforeProjection); XCTAssertEqual(e.pendingTurnCount, 0)
			let events = await finish(e)
			XCTAssertEqual(labels(events), ["stream:final_content", "identity", "stream:message_stop", "complete:completed"])
			guard case .turnCompleted(let id, _) = events.last else { return XCTFail("missing completion") }; XCTAssertEqual(id, turn)
			XCTAssertEqual(e.completions.count, 1)
		}
	}
	func testForwardedStreamMessageStopCannotCompleteATurn() async throws {
		let e = engine(); _ = e.openTurn()
		try e.consume(wire(#"{"type":"stream_event","event":{"type":"message_stop"}}"#), observe: { _ in })
		XCTAssertEqual(e.pendingTurnCount, 1); XCTAssertTrue(e.completions.isEmpty)
		let captured2 = labels(await finish(e)); XCTAssertEqual(captured2, ["stream:message_stop"])
	}
	func testDeferredResultCompletesOnlyAfterIdleStatusContent() async throws {
		let e = engine(); _ = e.openTurn(); try e.consume(state("running"), observe: { _ in })
		try e.consume(result(), observe: { _ in }); XCTAssertTrue(e.hasDeferredOutcomes); XCTAssertEqual(e.pendingTurnCount, 1)
		try e.consume(state("idle"), observe: { _ in }); XCTAssertFalse(e.hasDeferredOutcomes)
		let captured3 = labels(await finish(e)); XCTAssertEqual(captured3, ["stream:session_state_changed", "stream:final_content", "identity", "stream:message_stop", "stream:session_state_changed", "complete:completed"])
	}
	func testInterruptTargetsCapturedGenerationRatherThanNextResult() async throws {
		let e = engine(); let first = e.openTurn(), second = e.openTurn()
		let target = try XCTUnwrap(e.generation(for: second))
		e.applyLifecycle(e.ingestLifecycle(.host(.interruptRequested(target: target))), observe: { _ in })
		try e.consume(result(id: "a"), observe: { _ in }); try e.consume(result(id: "b"), observe: { _ in })
		let completed = (await finish(e)).compactMap { if case .turnCompleted(let id, let status) = $0 { return (id, status) }; return nil }
		XCTAssertEqual(completed.map { $0.0 }, [first, second]); XCTAssertEqual(completed.map { $0.1 }, [.completed, .cancelled])
	}
	func testEOFDrainRetainsObservedOutcomeAndErrorRowOrderingAcrossInitializationRetirement() async throws {
		let e = engine(); _ = e.openTurn(); try e.consume(state("running"), observe: { _ in }); try e.consume(result(), observe: { _ in }); _ = e.openTurn()
		let drain = e.ingestLifecycle(.host(.transportClosed))
		e.retireInitialization(); e.emit(.error("exit"), observe: { _ in }); e.applyLifecycle(drain, observe: { _ in }); e.clearTurns()
		let captured4 = labels(await finish(e)); XCTAssertEqual(Array(captured4.suffix(3)), ["error", "complete:completed", "complete:failed"])
	}
	func testShutdownAbandonsUnobservedTurnsWithoutInventedCompletion() async {
		let e = engine(); _ = e.openTurn(); var abandoned = 0
		e.applyLifecycle(e.ingestLifecycle(.host(.shutdownRequested))) { if case .lifecycleEffect(.abandoned) = $0 { abandoned += 1 } }
		XCTAssertEqual(abandoned, 1); XCTAssertEqual(e.pendingTurnCount, 0); let captured5 = await finish(e).isEmpty; XCTAssertTrue(captured5)
	}
	func testPendingLifecycleIsSingleUseAndForeignOwnerCannotApplyIt() async throws {
		let e = engine(), other = engine(); _ = e.openTurn()
		let pending = e.ingestLifecycle(.host(.protocolFailureOccurred)); other.applyLifecycle(pending, observe: { _ in }); e.applyLifecycle(pending, observe: { _ in }); e.applyLifecycle(pending, observe: { _ in })
		let captured6 = labels(await finish(e)); XCTAssertEqual(captured6, ["complete:failed"]); let captured7 = await finish(other).isEmpty; XCTAssertTrue(captured7)
	}
	func testTransportReplacementRetiresPendingLifecycleCapability() async {
		let e = engine(); _ = e.openTurn(); let pending = e.ingestLifecycle(.host(.protocolFailureOccurred))
		e.beginTransportEpoch(observe: { _ in }); e.applyLifecycle(pending, observe: { _ in })
		XCTAssertTrue(e.completions.isEmpty); let captured8 = await finish(e).isEmpty; XCTAssertTrue(captured8)
	}
	func testCorruptLedgerDispatchesOnlyTypedDriftAndNoCompletion() async {
		let e = engine(); let id = e.openTurn(); e.dropLedgerRecordForTesting(id: id); var drift = 0
		e.applyLifecycle(e.ingestLifecycle(.host(.protocolFailureOccurred))) { if case .lifecycleEffect(.drift(.completionForUnknownGeneration)) = $0 { drift += 1 } }
		XCTAssertEqual(drift, 1); let captured9 = await finish(e).isEmpty; XCTAssertTrue(captured9)
	}
	func testStaleProducerTokenCannotMutateMetadataContentOrLifecycle() async throws {
		let e = engine(); let old = e.token; e.beginTransportEpoch(observe: { _ in }); let before = e.observedInputCount
		try e.consume(result(), for: old, observe: { _ in XCTFail("stale observation") })
		try e.consume(wire(#"{"type":"system","subtype":"init","session_id":"old"}"#), for: old, observe: { _ in XCTFail("stale metadata") })
		XCTAssertNil(e.sessionID); XCTAssertEqual(e.observedInputCount, before); let captured10 = await finish(e).isEmpty; XCTAssertTrue(captured10)
	}
	func testReentrantTransportReplacementStopsOldFrameAndCompletion() async throws {
		let e = engine(); _ = e.openTurn(); var replaced = false
		try e.consume(result()) { if case .projection = $0 { replaced = true; e.beginTransportEpoch(observe: { _ in }) } }
		XCTAssertTrue(replaced); XCTAssertTrue(e.completions.isEmpty); let captured11 = await finish(e).isEmpty; XCTAssertTrue(captured11)
	}
	func testReentrantStreamResetConsumesOldLedgerWithoutLeakingOldFrameToNewStream() async throws {
		let e = engine(); _ = e.openTurn(); let old = e.events
		try e.consume(result()) { if case .streamResult = $0 { e.resetEventsForNewRun() } }
		XCTAssertEqual(e.pendingTurnCount, 0); XCTAssertEqual(e.completions.count, 1)
		let captured12 = await drain(old).isEmpty; XCTAssertTrue(captured12); let captured13 = await finish(e).isEmpty; XCTAssertTrue(captured13)
	}
	func testWillEmitCallbackReplacementCannotYieldIntoNewEventStream() async {
		let e = engine(); let old = e.events
		e.emit(.error("retired")) { if case .willEmit = $0 { e.resetEventsForNewRun() } }
		let captured14 = await drain(old).isEmpty; XCTAssertTrue(captured14); let captured15 = await finish(e).isEmpty; XCTAssertTrue(captured15)
	}
	func testBufferedStreamsRemainSeparateAndExplicitFinishReopensOnEnsure() async {
		let e = engine(); e.emit(.error("old"), observe: { _ in }); let old = e.events; let stamp = e.token
		e.resetEventsForNewRun(); e.emit(.error("rejected"), for: stamp, observe: { _ in }); e.emit(.error("new"), observe: { _ in })
		let captured16 = labels(await drain(old)); XCTAssertEqual(captured16, ["error"]); let captured17 = labels(await finish(e)); XCTAssertEqual(captured17, ["error"])
		e.ensureEventsReady(); XCTAssertTrue(e.isEventStreamOpen); e.emit(.error("reopened"), observe: { _ in }); let captured18 = labels(await finish(e)); XCTAssertEqual(captured18, ["error"])
	}
	func testTransportMetadataResetPreservesIdentityAndResetsPublicationDedupe() async throws {
		let e = engine(); e.recordSessionID(" s ", observe: { _ in }); e.publishRuntimeInit(observe: { _ in })
		e.beginTransportEpoch(observe: { _ in }); e.publishRuntimeInit(observe: { _ in })
		XCTAssertEqual(e.sessionID, "s"); let captured19 = labels(await finish(e)); XCTAssertEqual(captured19, ["init:s:false", "init:s:false"])
	}
	func testSuppressedChildTasksAreObservedWithoutTranscriptOrCompletionRows() async throws {
		let e = engine(); _ = e.openTurn(); var suppressed = 0
		try e.consume(wire(#"{"type":"system","subtype":"task_started","task_id":"child","description":"work"}"#)) { if case .streamResult(_, true) = $0 { suppressed += 1 } }
		XCTAssertEqual(suppressed, 1); XCTAssertEqual(e.pendingTurnCount, 1); let captured20 = await finish(e).isEmpty; XCTAssertTrue(captured20)
	}
	func testIndependentClientsKeepIdentityAndInvocationCorrelationSeparate() async throws {
		let a = engine(), b = engine(); a.recordSessionID("a", observe: { _ in })
		let payload = try wire(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"same","name":"Read","input":{}}]}}"#)
		try a.consume(payload, observe: { _ in }); try b.consume(payload, observe: { _ in })
		let aa = await finish(a), bb = await finish(b)
		let first = aa.compactMap { if case .stream(let result) = $0 { return result.toolInvocationID }; return nil }.first
		let second = bb.compactMap { if case .stream(let result) = $0 { return result.toolInvocationID }; return nil }.first
		XCTAssertNotNil(first); XCTAssertNotEqual(first, second); XCTAssertNil(b.sessionID)
	}
	func testInitializationOrdersSnapshotSettingsPermissionAdmissionAndReadiness() async throws {
		let e = engine(); e.beginLaunch(); e.storeSettings(try .init(object: ["subtype": "apply_flag_settings"]))
		let reply = try ClaudeProtocolJSONObject(object: ["session_id": "s", "commands": [["name": "help"]]])
		var order: [String] = []
		try await e.initialize(request: .init(object: ["subtype": "initialize"]), timeoutSeconds: 3, rpc: { request, timeout in
			let type = try request.dictionary()["subtype"] as? String
			if type == "initialize" { XCTAssertEqual(timeout, 3); return reply }
			XCTAssertNil(timeout); return try .init(object: [:])
		}, onResponse: { _ in order.append("response"); XCTAssertFalse(e.isInitialized) }, onSnapshot: { _, snapshot in
			order.append("snapshot"); XCTAssertEqual(snapshot.commands.first?.name, "help")
		}, observeSettings: { _ in order.append("settings") }, applyPermissionMode: { order.append("permission") }, admit: { _ in
			order.append("admit"); XCTAssertFalse(e.isInitialized)
		}, observe: { if case .willEmit(.runtimeInit(let value)) = $0 { order.append(value.initializeResponse == nil ? "identity" : "ready"); if value.initializeResponse != nil { XCTAssertTrue(e.isInitialized) } } })
		XCTAssertEqual(order, ["response", "identity", "snapshot", "settings", "permission", "admit", "ready"])
		let captured21 = labels(await finish(e)); XCTAssertEqual(captured21, ["init:s:false", "init:s:true"])
	}
	func testRejectedAdmissionNeverEstablishesReadinessOrPublishesReadySnapshot() async throws {
		let e = engine(); var permission = false
		do {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: ["session_id": "s"]) }, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, applyPermissionMode: { permission = true }, admit: { _ in throw FixtureError.rejected }, observe: { _ in })
			XCTFail("expected rejection")
		} catch { XCTAssertEqual(error as? FixtureError, .rejected) }
		XCTAssertTrue(permission); XCTAssertFalse(e.isInitialized); let captured22 = labels(await finish(e)); XCTAssertEqual(captured22, ["init:s:false"])
	}
	func testRetiredInitializeRPCDoesNotObserveOrAdmitLateResponse() async throws {
		let e = engine(); let gate = Gate(); let entered = gate.entered
		let task = Task {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in await gate.wait(); return try .init(object: ["session_id": "late"]) }, onResponse: { _ in XCTFail("late response") }, onSnapshot: { _, _ in XCTFail("late snapshot") }, observeSettings: { _ in }, applyPermissionMode: { XCTFail("late permission") }, admit: { _ in XCTFail("late admission") }, observe: { _ in XCTFail("late observation") })
		}
		var iterator = entered.makeAsyncIterator(); _ = await iterator.next(); e.retireInitialization(); await gate.release()
		do { try await task.value; XCTFail("retired initialization") } catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertFalse(e.isInitialized); XCTAssertNil(e.sessionID)
	}
	func testRetirementDuringAdmissionCannotPublishReadiness() async throws {
		let e = engine(); let gate = Gate(); let entered = gate.entered
		let task = Task {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: [:]) }, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, applyPermissionMode: {}, admit: { _ in await gate.wait() }, observe: { _ in })
		}
		var iterator = entered.makeAsyncIterator(); _ = await iterator.next(); e.retireInitialization(); await gate.release()
		do { try await task.value; XCTFail("retired admission") } catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertFalse(e.isInitialized); let captured23 = await finish(e).isEmpty; XCTAssertTrue(captured23)
	}
	func testSnapshotCallbackReplacementStopsPermissionAndAdmission() async throws {
		let e = engine()
		do {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: [:]) }, onResponse: { _ in }, onSnapshot: { _, _ in e.beginTransportEpoch(observe: { _ in }) }, observeSettings: { _ in XCTFail("retired settings") }, applyPermissionMode: { XCTFail("retired permission") }, admit: { _ in XCTFail("retired admission") }, observe: { _ in })
			XCTFail("replacement")
		} catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertFalse(e.isInitialized)
	}
	func testLiveSettingsShareInitializationOwnerAndFiveSecondDeadline() async throws {
		let e = engine(); let settings = try ClaudeProtocolJSONObject(object: ["model": "m"])
		let pending = try await e.applyLiveSettings(resolve: { settings }, isProcessAvailable: { true }, rpc: { _, _ in XCTFail("pre-initialize RPC"); return settings }, observeSettings: { _ in })
		XCTAssertEqual(pending, .pendingInitialization)
		try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: [:]) }, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, applyPermissionMode: {}, admit: { _ in }, observe: { _ in })
		let applied = try await e.applyLiveSettings(resolve: { settings }, isProcessAvailable: { true }, rpc: { request, timeout in XCTAssertEqual(timeout, 5); return request }, observeSettings: { _ in })
		XCTAssertEqual(applied, .applied)
	}
	func testRetirementDuringPermissionPreventsAdmission() async throws {
		let e = engine(); let gate = Gate(); let entered = gate.entered
		let task = Task {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: [:]) }, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, applyPermissionMode: { await gate.wait() }, admit: { _ in XCTFail("retired admission") }, observe: { _ in })
		}
		var iterator = entered.makeAsyncIterator(); _ = await iterator.next(); e.retireInitialization(); await gate.release()
		do { try await task.value; XCTFail("retired permission") } catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertFalse(e.isInitialized)
	}
	func testSystemInitObservationReplacementCannotPublishRetiredTools() async throws {
		let e = engine()
		try e.consume(wire(#"{"type":"system","subtype":"init","session_id":"s","tools":["old"]}"#)) {
			if case .systemInit = $0 { e.beginTransportEpoch(observe: { _ in }) }
		}
		XCTAssertTrue(e.runtimeSnapshot.tools.isEmpty)
		let events = await finish(e); XCTAssertEqual(labels(events), ["init:s:false"])
	}
	func testReadinessObservationRetirementCannotLeaveInitializedStateOrEmitReadySnapshot() async throws {
		let e = engine()
		do {
			try await e.initialize(request: .init(object: [:]), timeoutSeconds: nil, rpc: { _, _ in try .init(object: ["session_id": "s"]) }, onResponse: { _ in }, onSnapshot: { _, _ in }, observeSettings: { _ in }, applyPermissionMode: {}, admit: { _ in }, observe: {
				if case .willEmit(.runtimeInit(let status)) = $0, status.initializeResponse != nil { e.retireInitialization() }
			})
			XCTFail("retired readiness")
		} catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertFalse(e.isInitialized); let events = await finish(e); XCTAssertEqual(labels(events), ["init:s:false"])
	}

}
