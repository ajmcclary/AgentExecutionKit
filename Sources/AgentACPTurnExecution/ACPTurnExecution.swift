import Foundation
import AgentACPProtocol
import AgentACPEvents
import AgentRuntimeKit

/// Actor-confined prompt execution, event-stream ownership and terminal/settlement
/// authority. Async commands inherit their owner actor; no task captures mutable
/// executor state. Provider semantics, projection and side effects are injected.
public final class ACPTurnExecution {
	public struct Ticket: Hashable, Sendable {
		public let id: UUID
		fileprivate let epoch: UInt64
	}
	public typealias RPC = @Sendable (String, ACPJSONObject) async throws -> ACPJSONObject
	public typealias Sleep = @Sendable (Duration) async throws -> Void
	public enum ExecutionError: Error { case alreadyRunning, retired }
	private let settlements = TurnSettlementStore()
	private let sleep: Sleep
	private var epoch: UInt64 = 0
	private var current: Ticket?
	private var terminalClaimed = false
	public private(set) var hasEmittedTerminal = false
	public private(set) var streamFinished = false
	private var continuation: AsyncStream<ACPHeadlessRuntimeEvent>.Continuation?
	public private(set) var events: AsyncStream<ACPHeadlessRuntimeEvent>
	public var activeTurnID: UUID? { settlements.active }
	public var pendingSettlementWaiterCount: Int { settlements.waiterCount }

	public init(sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
		self.sleep = sleep
		let pair = AsyncStream<ACPHeadlessRuntimeEvent>.makeStream()
		events = pair.stream; continuation = pair.continuation
	}
	public func resetStream() {
		continuation?.finish()
		epoch &+= 1; current = nil; terminalClaimed = false; hasEmittedTerminal = false; streamFinished = false
		settlements.retire(with: ExecutionError.retired)
		let pair = AsyncStream<ACPHeadlessRuntimeEvent>.makeStream()
		events = pair.stream; continuation = pair.continuation
	}
	public func reopenBoundary() {
		if streamFinished { resetStream() }
		else if hasEmittedTerminal { terminalClaimed = false; hasEmittedTerminal = false }
	}
	public func emit(_ event: ACPHeadlessRuntimeEvent, for ticket: Ticket? = nil) {
		guard !streamFinished, !hasEmittedTerminal, ticket == nil || isCurrent(ticket!) else { return }
		continuation?.yield(event)
	}
	public func finishEvents() {
		guard !streamFinished else { return }
		streamFinished = true; continuation?.finish(); continuation = nil
		settlements.retire(with: ExecutionError.retired)
	}
	public func retire(with error: any Error) {
		epoch &+= 1; current = nil; settlements.retire(with: error)
	}
	private func isCurrent(_ ticket: Ticket) -> Bool { current == ticket && ticket.epoch == epoch }
	private func begin() throws -> Ticket {
		guard !streamFinished else { throw ExecutionError.retired }
		let ticket = Ticket(id: UUID(), epoch: epoch)
		guard settlements.begin(ticket.id) else { throw ExecutionError.alreadyRunning }
		current = ticket
		return ticket
	}

	public func submit(sessionID: String, rpc: RPC,
		onStarted: (Ticket) -> Void, prepare: (Ticket) throws -> [ACPJSONObject],
		onReply: (Ticket, Result<ACPJSONObject, any Error>) -> Void,
		afterReply: (Ticket) async -> Void,
		onSuccess: (Ticket, ACPJSONObject) -> Void, onFailure: (Ticket, any Error) async -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws {
		let ticket = try begin()
		onStarted(ticket)
		let response: ACPJSONObject
		do {
			guard isCurrent(ticket), !hasEmittedTerminal else { throw ExecutionError.retired }
			let blocks = try prepare(ticket)
			response = try await rpc("session/prompt", .init(object: ["sessionId": sessionID, "prompt": blocks.map { try $0.dictionary() }]))
		} catch {
			if isCurrent(ticket) { onReply(ticket, .failure(error)) }
			await afterReply(ticket)
			if isCurrent(ticket), !hasEmittedTerminal { await onFailure(ticket, error) }
			settlements.settle(ticket.id, result: .failure(error))
			throw error
		}
		if isCurrent(ticket) { onReply(ticket, .success(response)) }
		await afterReply(ticket)
		if isCurrent(ticket), !hasEmittedTerminal { onSuccess(ticket, response) }
		settlements.settle(ticket.id, result: .success(()))
	}

	/// Claim before provider/permission call-outs. Recursive finalization is a no-op.
	/// The host emits disposition events through emit before this writes the terminal.
	@discardableResult
	public func finalize(state: AgentSessionRunState, errorText: String?, for ticket: Ticket? = nil,
		beforeTerminal: () -> Void) -> Bool {
		guard !terminalClaimed, !streamFinished, ticket == nil || isCurrent(ticket!) else { return false }
		let stamp = epoch
		terminalClaimed = true
		beforeTerminal()
		guard epoch == stamp, !hasEmittedTerminal, !streamFinished, ticket == nil || isCurrent(ticket!) else { return false }
		hasEmittedTerminal = true
		continuation?.yield(.terminal(state: state, errorText: errorText))
		return true
	}
	public func settle(_ turnID: UUID, result: Result<Void, any Error>) { settlements.settle(turnID, result: result) }

	public func waitForSettlement(_ turnID: UUID, isolation: isolated (any Actor)? = #isolation) async throws {
		guard let slot = settlements.reserve(turnID) else { return }
		let settlements = self.settlements
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { slot.install($0) }
		} onCancel: { settlements.cancel(turnID, slot: slot) }
	}
	public func waitForSettlement(_ turnID: UUID, timeout: Duration, timeoutError: @escaping @Sendable () -> any Error,
		isolation: isolated (any Actor)? = #isolation) async throws {
		guard let slot = settlements.reserve(turnID) else { return }
		let settlements = self.settlements, sleep = self.sleep
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask {
				try await withTaskCancellationHandler {
					try await withCheckedThrowingContinuation { slot.install($0) }
				} onCancel: { settlements.cancel(turnID, slot: slot) }
			}
			group.addTask { try await sleep(timeout); throw timeoutError() }
			defer { group.cancelAll() }
			try await group.next()
		}
	}
	public static func cancelNotification(sessionID: String) throws -> ACPJSONObject {
		try .init(object: ["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])
	}
	deinit { continuation?.finish(); settlements.retire(with: ExecutionError.retired) }
}
