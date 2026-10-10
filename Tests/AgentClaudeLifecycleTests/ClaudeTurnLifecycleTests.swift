import XCTest
import Foundation
import ClaudeRuntimeKit
@_spi(Testing) import AgentClaudeLifecycle

final class ClaudeTurnLifecycleTests: XCTestCase {
	private func wire(_ phase: ClaudeLifecycleEvent.Phase, session: String? = "s", scope: ClaudeLifecycleScope = .topLevel) -> ClaudeLifecycleInput {
		.wire(.init(phase: phase, identity: .init(sessionID: session, messageID: nil, taskID: nil), scope: scope))
	}
	@discardableResult
	private func apply(_ owner: ClaudeTurnLifecycle, _ input: ClaudeLifecycleInput,
		outcome: ClaudeTurnOutcome? = nil) -> [ClaudeTurnLifecycle.Effect] {
		var effects: [ClaudeTurnLifecycle.Effect] = []
		owner.apply(owner.ingest(input, observedOutcome: outcome), onEffect: { effects.append($0) })
		return effects
	}
	private func completedIDs(_ effects: [ClaudeTurnLifecycle.Effect]) -> [UUID] {
		effects.compactMap { if case .completed(let turn, _, _) = $0 { return turn.id }; return nil }
	}
	private func drifts(_ effects: [ClaudeTurnLifecycle.Effect]) -> [ClaudeLifecycleDrift.Site] {
		effects.compactMap { if case .drift(let site) = $0 { return site }; return nil }
	}

	func testIdentityGenerationAndTransportStampHaveIndependentOwnership() {
		let owner = ClaudeTurnLifecycle(); let id = UUID(); let first = owner.openTurn(id: id)
		XCTAssertEqual(first.id, id); XCTAssertEqual(first.generation.value, 1)
		XCTAssertEqual(owner.generation(for: id), first.generation)
		let old = owner.ingest(.host(.interruptRequested(target: first.generation)))
		XCTAssertEqual(old.observation.stamped.epoch.value, 0)
		owner.clearTurns(); owner.beginNewEpoch()
		let second = owner.openTurn()
		XCTAssertEqual(second.generation.value, 2)
		XCTAssertEqual(owner.ingest(.host(.transportReestablished)).observation.stamped.epoch.value, 1)
		XCTAssertEqual(old.observation.stamped.epoch.value, 0)
	}
	func testResultCompletionIsHeldUntilContentWasDelivered() {
		let owner = ClaudeTurnLifecycle(); let turn = owner.openTurn()
		let batch = owner.ingest(wire(.resultObserved), observedOutcome: .completed)
		XCTAssertEqual(owner.pendingTurnCount, 1); XCTAssertTrue(owner.completions.isEmpty)
		var order = ["content"]
		XCTAssertTrue(owner.apply(batch) { effect in
			guard case .completed(let completed, let outcome, let trigger) = effect else { return XCTFail("Expected completion") }
			XCTAssertEqual(completed, turn); XCTAssertEqual(outcome, .completed); XCTAssertEqual(trigger, .resultWithoutIdleBoundary)
			XCTAssertFalse(owner.hasOpenTurns); XCTAssertEqual(owner.completions.count, 1)
			order.append("completed")
		})
		XCTAssertEqual(order, ["content", "completed"])
	}
	func testDeferredOutcomeKeepsLedgerOpenUntilIdle() {
		let owner = ClaudeTurnLifecycle(); let turn = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running)))
		XCTAssertTrue(apply(owner, wire(.resultObserved), outcome: .failed).isEmpty)
		XCTAssertTrue(owner.hasDeferredOutcomes); XCTAssertEqual(owner.headTurnGeneration, turn.generation)
		XCTAssertEqual(completedIDs(apply(owner, wire(.runStateChanged(.idle)))), [turn.id])
		XCTAssertEqual(owner.completions, [.init(turn: turn.generation, outcome: .failed, trigger: .idleBoundary)])
		XCTAssertFalse(owner.hasDeferredOutcomes)
	}
	func testEarlyIdleIsRememberedAtResult() {
		let owner = ClaudeTurnLifecycle(); let turn = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.idle)))
		XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))), [turn.id])
		XCTAssertEqual(owner.completions.first?.trigger, .rememberedIdleAtResult)
	}
	func testDuplicateResultDriftsWithoutClosingDeferredTurn() {
		let owner = ClaudeTurnLifecycle(); let turn = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running))); _ = apply(owner, wire(.resultObserved))
		XCTAssertEqual(drifts(apply(owner, wire(.resultObserved))), [.duplicateResultForOpenTurn])
		XCTAssertEqual(owner.pendingTurnCount, 1)
		XCTAssertEqual(completedIDs(apply(owner, .host(.idleFallbackFired))), [turn.id])
		XCTAssertEqual(owner.completions.first?.trigger, .fallbackTimer)
	}
	func testDeferredFIFORecordsRetainTheirOwnOutcomes() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running)))
		_ = apply(owner, wire(.resultObserved), outcome: .failed); _ = apply(owner, wire(.resultObserved), outcome: .cancelled)
		XCTAssertEqual(completedIDs(apply(owner, wire(.runStateChanged(.idle)))), [first.id])
		XCTAssertTrue(owner.hasDeferredOutcomes); XCTAssertEqual(owner.headTurnGeneration, second.generation)
		XCTAssertEqual(completedIDs(apply(owner, .host(.idleFallbackFired))), [second.id])
		XCTAssertEqual(owner.completions.map(\.outcome), [.failed, .cancelled])
		XCTAssertFalse(owner.hasOpenTurns)
	}
	func testInterruptTargetsNamedTurnRatherThanNextResult() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		_ = apply(owner, .host(.interruptRequested(target: second.generation)))
		XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))), [first.id])
		XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))), [second.id])
		XCTAssertEqual(owner.completions.map(\.outcome), [.completed, .cancelled])
	}
	func testShutdownPreservesObservedOutcomeAndAbandonsUnobservedTurn() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running))); _ = apply(owner, wire(.resultObserved), outcome: .cancelled)
		let effects = apply(owner, .host(.shutdownRequested))
		XCTAssertEqual(completedIDs(effects), [first.id])
		guard effects.count == 2, case .abandoned(let turn) = effects.last else { return XCTFail("Expected abandonment") }
		XCTAssertEqual(turn, second); XCTAssertFalse(owner.hasOpenTurns); XCTAssertFalse(owner.hasDeferredOutcomes)
		XCTAssertEqual(owner.completions, [.init(turn: first.generation, outcome: .cancelled, trigger: .teardownDrain)])
	}
	func testTransportLossPreservesDeferredOutcomeThenFailsUnobservedTurns() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running))); _ = apply(owner, wire(.resultObserved), outcome: .completed)
		XCTAssertEqual(completedIDs(apply(owner, .host(.transportClosed))), [first.id, second.id])
		XCTAssertEqual(owner.completions.map(\.outcome), [.completed, .failed])
		XCTAssertEqual(owner.completions.map(\.trigger), [.teardownDrain, .transportEndedStale])
	}
	func testProtocolFailureRetainsExistingFailAllPolicy() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		_ = apply(owner, wire(.runStateChanged(.running))); _ = apply(owner, wire(.resultObserved), outcome: .completed)
		XCTAssertEqual(completedIDs(apply(owner, .host(.protocolFailureOccurred))), [first.id, second.id])
		XCTAssertEqual(owner.completions.map(\.outcome), [.failed, .failed])
		XCTAssertEqual(owner.completions.map(\.trigger), [.protocolFailure, .protocolFailure])
	}
	func testChildAndUnresolvedEventsCannotCompleteTopLevelTurn() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn()
		for scope in [ClaudeLifecycleScope.child, .unresolved] {
			XCTAssertTrue(apply(owner, wire(.resultObserved, scope: scope)).isEmpty)
		}
		XCTAssertTrue(apply(owner, wire(.childTaskNotification, scope: .child)).isEmpty)
		XCTAssertEqual(owner.pendingTurnCount, 1); XCTAssertTrue(owner.completions.isEmpty)
	}
	func testForeignSessionQuarantineNeverRetargetsNewestTurn() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); _ = apply(owner, wire(.resultObserved, session: "first"))
		let turn = owner.openTurn()
		XCTAssertEqual(drifts(apply(owner, wire(.resultObserved, session: "foreign"))), [.resultForUnrecognizedSession])
		XCTAssertEqual(owner.generation(for: turn.id), turn.generation)
	}
	func testBatchCopiesAndRecursiveApplyAreExactlyOnce() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); let batch = owner.ingest(wire(.resultObserved)); let copy = batch
		var count = 0
		XCTAssertTrue(owner.apply(batch) { _ in
			count += 1; XCTAssertFalse(owner.apply(copy) { _ in XCTFail("Recursive duplicate") })
		})
		XCTAssertFalse(owner.apply(copy) { _ in XCTFail("Duplicate") }); XCTAssertEqual(count, 1)
	}
	func testForeignOwnerCannotApplyOrConsumeAnotherOwnersBatch() {
		let owner = ClaudeTurnLifecycle(); let foreign = ClaudeTurnLifecycle(); _ = owner.openTurn(); _ = foreign.openTurn()
		let batch = owner.ingest(wire(.resultObserved))
		XCTAssertFalse(foreign.apply(batch) { _ in XCTFail("Foreign batch") })
		XCTAssertTrue(owner.apply(batch) { _ in }); XCTAssertEqual(foreign.pendingTurnCount, 1)
	}
	func testReplacedEpochRejectsDelayedBatchWithoutTouchingNewTurn() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); let old = owner.ingest(wire(.resultObserved))
		owner.clearTurns(); owner.beginNewEpoch(); _ = apply(owner, .host(.transportReestablished)); let new = owner.openTurn()
		XCTAssertFalse(owner.apply(old) { _ in XCTFail("Retired epoch") })
		XCTAssertEqual(owner.generation(for: new.id), new.generation)
		XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))), [new.id])
	}
	func testReentrantTransportReplacementStopsRemainingOldEffects() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); _ = owner.openTurn()
		let batch = owner.ingest(.host(.transportClosed)); var count = 0; var new: ClaudeTurnLifecycle.Turn?
		owner.apply(batch) { _ in
			count += 1; owner.clearTurns(); owner.beginNewEpoch(); new = owner.openTurn()
		}
		XCTAssertEqual(count, 1); XCTAssertEqual(owner.pendingTurnCount, 1)
		XCTAssertEqual(owner.headTurnGeneration, new?.generation)
	}
	func testBoundedHistoryNeverBoundsExecutionOrObservedCount() {
		let owner = ClaudeTurnLifecycle(historyCapacity: 2)
		for _ in 0..<20 { _ = owner.openTurn(); XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))).count, 1) }
		XCTAssertEqual(owner.observations.count, 2); XCTAssertEqual(owner.completions.count, 2)
		XCTAssertEqual(owner.observedInputCount, 20); XCTAssertFalse(owner.hasOpenTurns)
	}
	func testMissingLedgerGenerationRecordsDriftRatherThanCompletingAnotherTurn() {
		let owner = ClaudeTurnLifecycle(); let first = owner.openTurn(); let second = owner.openTurn()
		owner.dropLedgerRecordForTesting(id: first.id)
		XCTAssertEqual(drifts(apply(owner, wire(.resultObserved))), [.completionForUnknownGeneration])
		XCTAssertEqual(owner.generation(for: second.id), second.generation); XCTAssertTrue(owner.completions.isEmpty)
	}
	func testClearingLedgerRetiresPendingDispatchWithoutChangingTransportStamp() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); let old = owner.ingest(wire(.resultObserved))
		owner.clearTurns(); let next = owner.openTurn()
		XCTAssertFalse(owner.apply(old) { _ in XCTFail("Retired ledger") })
		let fresh = owner.ingest(wire(.resultObserved))
		XCTAssertEqual(fresh.observation.stamped.epoch, old.observation.stamped.epoch)
		var ids: [UUID] = []
		owner.apply(fresh) { if case .completed(let turn, _, _) = $0 { ids.append(turn.id) } }
		XCTAssertEqual(ids, [next.id])
	}
	func testClearingLedgerAlsoForgetsRuntimeOpenGenerations() {
		let owner = ClaudeTurnLifecycle(); _ = owner.openTurn(); owner.clearTurns(); let turn = owner.openTurn()
		XCTAssertEqual(completedIDs(apply(owner, wire(.resultObserved))), [turn.id])
	}
	func testLargeLedgerMaintainsOrderWithoutRetainedHistory() {
		let owner = ClaudeTurnLifecycle(historyCapacity: 0); let ids = (0..<600).map { _ in owner.openTurn().id }
		XCTAssertEqual(completedIDs(apply(owner, .host(.transportClosed))), ids)
		XCTAssertTrue(owner.completions.isEmpty); XCTAssertTrue(owner.observations.isEmpty); XCTAssertFalse(owner.hasOpenTurns)
	}
}
