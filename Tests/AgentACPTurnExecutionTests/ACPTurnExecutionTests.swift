import Foundation
import Synchronization
import XCTest
import AgentACPProtocol
import AgentACPEvents
import AgentRuntimeKit
@testable import AgentACPTurnExecution

private enum Failure: Error, Equatable { case rpc, prepare, timeout, retired }
@MainActor
private final class Fixture {
	let executor: ACPTurnExecution
	var ticket: ACPTurnExecution.Ticket?
	var calls: [(String, ACPJSONObject)] = []
	var phases: [String] = []
	var pending: CheckedContinuation<ACPJSONObject, any Error>?
	var hold = false, prepareFails = false, rpcFails = false, holdAfter = false
	var afterGate: CheckedContinuation<Void, Never>?
	var successes = 0, failures = 0
	init(sleep: @escaping ACPTurnExecution.Sleep = { try await Task.sleep(for: $0) }) { executor = .init(sleep: sleep) }
	var rpc: ACPTurnExecution.RPC { { [weak self] method, payload in guard let self else { throw Failure.retired }; return try await self.send(method, payload) } }
	func send(_ method: String, _ payload: ACPJSONObject) async throws -> ACPJSONObject {
		calls.append((method, payload))
		if rpcFails { throw Failure.rpc }
		if hold { return try await withCheckedThrowingContinuation { pending = $0 } }
		return try .init(object: ["stopReason": "end_turn"])
	}
	func run() async throws {
		try await executor.submit(sessionID: " raw ", rpc: rpc,
			onStarted: { ticket = $0; phases.append("started") },
			prepare: { _ in
				if prepareFails { throw Failure.prepare }
				return [try .init(object: ["type": "text", "text": "hé 🧭"])]
			}, onReply: { _, outcome in if case .success = outcome { phases.append("reply") } else { phases.append("error") } },
			afterReply: { _ in
				phases.append("after")
				if holdAfter { await withCheckedContinuation { afterGate = $0 } }
			},
			onSuccess: { ticket, _ in
				successes += 1
				executor.finalize(state: .completed, errorText: nil, for: ticket) {
					executor.emit(.stream(.init(type: "message_stop", text: nil)), for: ticket)
				}
			}, onFailure: { ticket, _ in
				failures += 1; executor.finalize(state: .failed, errorText: "fixture", for: ticket) {}
			})
	}
	func waitPending() async throws {
		for _ in 0..<1000 { if pending != nil { return }; try await Task.sleep(for: .milliseconds(1)) }
		XCTFail("No suspended RPC"); throw Failure.rpc
	}
	func release(_ result: Result<ACPJSONObject, any Error>) { pending?.resume(with: result); pending = nil }
}

@MainActor
final class ACPTurnExecutionTests: XCTestCase {
	func testSubmissionUsesExactSessionAndPreparedBlocksAndOrderedHooks() async throws {
		let f = Fixture(); let stream = f.executor.events; try await f.run(); f.executor.finishEvents()
		XCTAssertEqual(f.phases, ["started", "reply", "after"]); XCTAssertEqual(f.successes, 1)
		let payload = try f.calls[0].1.dictionary()
		XCTAssertEqual(f.calls[0].0, "session/prompt"); XCTAssertEqual(payload["sessionId"] as? String, " raw ")
		XCTAssertEqual(((payload["prompt"] as? [[String: Any]])?.first)?["text"] as? String, "hé 🧭")
		var kinds: [String] = []
		for await event in stream { switch event { case .stream: kinds.append("stop"); case .terminal: kinds.append("terminal"); default: break } }
		XCTAssertEqual(kinds, ["stop", "terminal"]); XCTAssertNil(f.executor.activeTurnID)
	}
	func testPreparationAndRPCFailuresRunHooksAndSettleWaiters() async throws {
		for preparation in [true, false] {
			let f = Fixture(); f.prepareFails = preparation; f.rpcFails = !preparation
			do { try await f.run(); XCTFail("Expected failure") } catch { XCTAssertEqual(error as? Failure, preparation ? .prepare : .rpc) }
			XCTAssertEqual(f.failures, 1); XCTAssertEqual(f.phases, ["started", "error", "after"]); XCTAssertNil(f.executor.activeTurnID)
			XCTAssertTrue(f.executor.hasEmittedTerminal)
		}
	}
	func testDuplicateSubmissionRejectedWithoutAnotherRPC() async throws {
		let f = Fixture(); f.hold = true
		let first = Task { try await f.run() }; try await f.waitPending()
		do { try await f.run(); XCTFail("Duplicate") } catch { XCTAssertTrue(error is ACPTurnExecution.ExecutionError) }
		XCTAssertEqual(f.calls.count, 1); f.release(.success(.empty)); try await first.value
	}
	func testTerminalClaimsBeforeCallbacksAndDispositionPrecedesTerminal() async throws {
		let f = Fixture(); let stream = f.executor.events; var finalizations = 0
		XCTAssertTrue(f.executor.finalize(state: .failed, errorText: "one") {
			finalizations += 1
			XCTAssertFalse(f.executor.finalize(state: .failed, errorText: "two") { finalizations += 100 })
			f.executor.emit(.approvalCancelled(.acp("i:1")))
		})
		XCTAssertFalse(f.executor.finalize(state: .failed, errorText: nil) {})
		f.executor.emit(.stream(.init(type: "late", text: nil))); f.executor.finishEvents()
		var order: [String] = []
		for await event in stream { switch event { case .approvalCancelled: order.append("cancel"); case .terminal: order.append("terminal"); default: order.append("late") } }
		XCTAssertEqual(order, ["cancel", "terminal"]); XCTAssertEqual(finalizations, 1)
	}
	func testReentrantStreamReplacementCannotReceiveOldTerminal() async throws {
		let f = Fixture(); let old = f.executor.events
		XCTAssertFalse(f.executor.finalize(state: .failed, errorText: nil) { f.executor.resetStream() })
		f.executor.finishEvents()
		var count = 0; for await _ in old { count += 1 }; XCTAssertEqual(count, 0)
		XCTAssertFalse(f.executor.hasEmittedTerminal)
	}
	func testOldRPCCompletionCannotCommitToReplacementStream() async throws {
		let f = Fixture(); f.hold = true
		let old = Task { try await f.run() }; try await f.waitPending(); let ticket = try XCTUnwrap(f.ticket)
		f.executor.resetStream(); f.executor.emit(.stream(.init(type: "replacement", text: nil)))
		f.release(.success(.empty)); try await old.value
		XCTAssertEqual(f.successes, 0); XCTAssertFalse(f.executor.hasEmittedTerminal)
		XCTAssertFalse(f.executor.finalize(state: .completed, errorText: nil, for: ticket) {})
		f.executor.finishEvents()
	}
	func testEarlyTerminalPreventsSuccessOrFailureHookFromReopeningTurn() async throws {
		for failure in [false, true] {
			let f = Fixture(); f.hold = true
			let task = Task { try await f.run() }; try await f.waitPending()
			f.executor.finalize(state: .cancelled, errorText: nil) {}
			f.release(failure ? .failure(Failure.rpc) : .success(.empty))
			_ = await task.result
			XCTAssertEqual(f.successes, 0); XCTAssertEqual(f.failures, 0); XCTAssertNil(f.executor.activeTurnID)
		}
	}
	func testReplacementWhileAfterReplySuspendedFencesSuccess() async throws {
		let f = Fixture(); f.holdAfter = true
		let task = Task { try await f.run() }
		for _ in 0..<1000 { if f.afterGate != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
		XCTAssertNotNil(f.afterGate); f.executor.resetStream(); f.afterGate?.resume(); f.afterGate = nil
		try await task.value; XCTAssertEqual(f.successes, 0); XCTAssertFalse(f.executor.hasEmittedTerminal)
	}
	func testMultipleSettlementWaitersCompleteExactlyOnce() async throws {
		let f = Fixture(); f.hold = true
		let prompt = Task { try await f.run() }; try await f.waitPending(); let id = try XCTUnwrap(f.ticket).id
		let a = Task { try await f.executor.waitForSettlement(id) }, b = Task { try await f.executor.waitForSettlement(id) }
		for _ in 0..<1000 { if f.executor.pendingSettlementWaiterCount == 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
		XCTAssertEqual(f.executor.pendingSettlementWaiterCount, 2); f.release(.success(.empty)); try await prompt.value; try await a.value; try await b.value
		f.executor.settle(id, result: .failure(Failure.rpc))
		try await f.executor.waitForSettlement(id)
	}
	func testCancelledAndPreCancelledWaitersDoNotPoisonPrompt() async throws {
		let f = Fixture(); f.hold = true
		let prompt = Task { try await f.run() }; try await f.waitPending(); let id = try XCTUnwrap(f.ticket).id
		let waiter = Task { try await f.executor.waitForSettlement(id) }; waiter.cancel()
		do { try await waiter.value; XCTFail("Cancelled waiter") } catch { XCTAssertTrue(error is CancellationError) }
		XCTAssertEqual(f.executor.activeTurnID, id); f.release(.success(.empty)); try await prompt.value
	}
	func testInjectedTimeoutCancelsWaiterWithoutCancellingPrompt() async throws {
		let f = Fixture(sleep: { _ in }); f.hold = true
		let prompt = Task { try await f.run() }; try await f.waitPending(); let id = try XCTUnwrap(f.ticket).id
		do { try await f.executor.waitForSettlement(id, timeout: .seconds(1), timeoutError: { Failure.timeout }); XCTFail("Timeout") }
		catch { XCTAssertEqual(error as? Failure, .timeout) }
		XCTAssertEqual(f.executor.activeTurnID, id); f.release(.success(.empty)); try await prompt.value
	}
	func testFinishAndRetireReleaseWaitersAndDoNotTouchNewTurn() async throws {
		let f = Fixture(); f.hold = true
		let prompt = Task { try await f.run() }; try await f.waitPending(); let id = try XCTUnwrap(f.ticket).id
		let waiter = Task { try await f.executor.waitForSettlement(id) }
		for _ in 0..<1000 { if f.executor.pendingSettlementWaiterCount == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
		XCTAssertEqual(f.executor.pendingSettlementWaiterCount, 1)
		f.executor.retire(with: Failure.retired)
		do { try await waiter.value; XCTFail("Retired waiter") } catch { XCTAssertEqual(error as? Failure, .retired) }
		f.executor.finishEvents(); f.release(.failure(Failure.rpc)); _ = await prompt.result
		XCTAssertEqual(f.failures, 0); XCTAssertNil(f.executor.activeTurnID)
	}
	func testCancelNotificationKeepsByteExactIdentity() throws {
		let object = try ACPTurnExecution.cancelNotification(sessionID: " raw ").dictionary()
		XCTAssertEqual(object["method"] as? String, "session/cancel")
		XCTAssertEqual((object["params"] as? [String: Any])?["sessionId"] as? String, " raw ")
		XCTAssertNil(object["id"])
	}
	func testConcurrentReservationCancellationAndSettlementHaveOneWinner() async throws {
		for _ in 0..<50 {
			let store = TurnSettlementStore(); let id = UUID(); XCTAssertTrue(store.begin(id))
			let slot = try XCTUnwrap(store.reserve(id))
			await withTaskGroup(of: Void.self) { group in
				group.addTask { store.cancel(id, slot: slot) }
				group.addTask { store.settle(id, result: .success(())) }
			}
			do { try await withCheckedThrowingContinuation { slot.install($0) } }
			catch { XCTAssertTrue(error is CancellationError) }
			XCTAssertEqual(store.waiterCount, 0); XCTAssertNil(store.active)
		}
	}

	func testReservedSlotCancellationAndCompletionBeforeRegistration() async throws {
		let store = TurnSettlementStore(); let id = UUID(); XCTAssertTrue(store.begin(id))
		let a = try XCTUnwrap(store.reserve(id)); store.cancel(id, slot: a)
		do { try await withCheckedThrowingContinuation { a.install($0) }; XCTFail("Cancellation") } catch { XCTAssertTrue(error is CancellationError) }
		let b = try XCTUnwrap(store.reserve(id)); store.settle(id, result: .success(()))
		try await withCheckedThrowingContinuation { b.install($0) }
		XCTAssertNil(store.reserve(id))
	}
}
