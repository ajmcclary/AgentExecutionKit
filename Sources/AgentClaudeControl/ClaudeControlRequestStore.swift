import Foundation
import Synchronization
import AgentClaudeProtocol

/// Deadline tasks hold only this Sendable store. Every removal precedes cancellation,
/// continuation resume and host callbacks; the mutex is never held across a call-out.
final class ClaudeControlRequestStore: Sendable {
	typealias Ticket = ClaudeControlChannel.Ticket
	typealias Deadline = ClaudeControlChannel.Deadline
	static let emptyObject = try! ClaudeProtocolJSONObject(data: Data("{}".utf8))
	struct Pending: Sendable {
		let ticket: Ticket
		let continuation: CheckedContinuation<ClaudeProtocolJSONObject, any Error>
		var timer: Task<Void, Never>?
	}
	private struct State: Sendable {
		var nextID = 1
		var pending: [String: Pending] = [:]
	}
	private let state = Mutex(State())
	private let prefix: String
	private let sleep: ClaudeControlChannel.Sleep
	init(prefix: String, sleep: @escaping ClaudeControlChannel.Sleep) { self.prefix = prefix; self.sleep = sleep }
	func nextTicket() throws -> Ticket {
		try state.withLock { state in
			guard state.nextID < Int.max else { throw ClaudeControlChannel.ChannelError.identifiersExhausted }
			defer { state.nextID += 1 }
			return Ticket(requestID: "\(prefix)\(state.nextID)", token: UUID())
		}
	}
	func register(_ ticket: Ticket, continuation: CheckedContinuation<ClaudeProtocolJSONObject, any Error>, deadline: Deadline?) {
		state.withLock { $0.pending[ticket.requestID] = Pending(ticket: ticket, continuation: continuation) }
		guard let deadline, deadline.duration > .zero else { return }
		let sleep = self.sleep
		let timer = Task { [weak self] in
			do { try await sleep(deadline.duration) } catch { return }
			guard !Task.isCancelled, self?.contains(ticket) == true else { return }
			await deadline.onExpiry(ticket)
		}
		let installed = state.withLock { state in
			guard state.pending[ticket.requestID]?.ticket == ticket else { return false }
			state.pending[ticket.requestID]?.timer = timer; return true
		}
		if !installed { timer.cancel() }
	}
	private func contains(_ ticket: Ticket) -> Bool { state.withLock { $0.pending[ticket.requestID]?.ticket == ticket } }
	func take(_ id: String) -> Pending? { state.withLock { $0.pending.removeValue(forKey: id) } }
	@discardableResult
	func fail(_ ticket: Ticket, with error: any Error) -> Bool { fail(ticket, makeError: { error }) }
	@discardableResult
	func fail(_ ticket: Ticket, makeError: () -> any Error) -> Bool {
		let pending = state.withLock { state -> Pending? in
			guard state.pending[ticket.requestID]?.ticket == ticket else { return nil }
			return state.pending.removeValue(forKey: ticket.requestID)
		}
		guard let pending else { return false }
		pending.timer?.cancel(); pending.continuation.resume(throwing: makeError()); return true
	}
	private func drain() -> [Pending] {
		state.withLock { state in
			let values = Array(state.pending.values); state.pending.removeAll(); return values
		}
	}
	func failAll(with error: any Error) {
		for pending in drain() { pending.timer?.cancel(); pending.continuation.resume(throwing: error) }
	}
	var pendingRequestIDs: [String] { state.withLock { $0.pending.keys.sorted() } }
	deinit {
		for pending in drain() {
			pending.timer?.cancel(); pending.continuation.resume(throwing: ClaudeControlChannel.ChannelError.released)
		}
	}
}
