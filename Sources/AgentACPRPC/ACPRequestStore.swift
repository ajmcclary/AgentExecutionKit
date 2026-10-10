import Foundation
import Synchronization

/// Owns pending RPC continuations and deadlines. Removal precedes every call-out;
/// responses, write failures, explicit cancellation, and teardown race exactly once.
/// Payload bytes are immutable across isolation boundaries. Host code owns decoding,
/// timeout selection and diagnostics, and decides whether caller cancellation cancels RPC.
public final class ACPRequestStore: Sendable {
	public struct Ticket: Hashable, Sendable {
		public let id: ACPRequestID
		public let method: String
		private let token: UUID
		fileprivate init(id: ACPRequestID, method: String) {
			self.id = id
			self.method = method
			self.token = UUID()
		}
	}
	public struct Deadline: Sendable {
		public let duration: Duration
		public let onExpiry: @Sendable (Ticket) async -> Void
		public init(duration: Duration, onExpiry: @escaping @Sendable (Ticket) async -> Void) {
			self.duration = duration
			self.onExpiry = onExpiry
		}
	}
	public enum StoreError: Error { case closed, identifiersExhausted }
	public enum ResponseMatching: Sendable { case strict, canonicalNumericEcho }
	public typealias Sleep = @Sendable (Duration) async throws -> Void
	private struct Pending: Sendable {
		let ticket: Ticket
		let continuation: CheckedContinuation<Data, any Error>
		var timer: Task<Void, Never>?
	}
	private struct State: Sendable {
		var nextID = 1
		var pending: [String: Pending] = [:]
	}
	private let state = Mutex(State())
	private let matching: ResponseMatching
	private let sleep: Sleep

	public init(matching: ResponseMatching = .canonicalNumericEcho,
				sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
		self.matching = matching
		self.sleep = sleep
	}

	/// Registers before the caller writes the request. IDs remain monotonic after failAll.
	public func register(method: String, continuation: CheckedContinuation<Data, any Error>,
						 deadline: Deadline? = nil) throws -> Ticket {
		let ticket = try state.withLock { state in
			guard state.nextID < Int.max else { throw StoreError.identifiersExhausted }
			let ticket = Ticket(id: .int(state.nextID), method: method)
			state.nextID += 1
			state.pending[ticket.id.storageKey] = Pending(ticket: ticket, continuation: continuation)
			return ticket
		}
		if let deadline, deadline.duration > .zero {
			let sleep = self.sleep
			let timer = Task { [weak self] in
				do { try await sleep(deadline.duration) } catch { return }
				guard !Task.isCancelled, self?.contains(ticket) == true else { return }
				// Deliver to the host executor before claiming. This preserves actor-ordered
				// replies/deadlines; the host calls expire on that executor.
				await deadline.onExpiry(ticket)
			}
			let installed = state.withLock { state in
				guard state.pending[ticket.id.storageKey]?.ticket == ticket else { return false }
				state.pending[ticket.id.storageKey]?.timer = timer
				return true
			}
			if !installed { timer.cancel() }
		}
		return ticket
	}

	@discardableResult
	public func resolve(responseID: ACPRequestID, with result: Result<Data, any Error>) -> Ticket? {
		let keys = matching == .strict ? [responseID.storageKey] : responseID.compatibleResponseKeys
		let pending = state.withLock { state -> Pending? in
			for key in keys {
				if let pending = state.pending.removeValue(forKey: key) { return pending }
			}
			return nil
		}
		guard let pending else { return nil }
		pending.timer?.cancel()
		pending.continuation.resume(with: result)
		return pending.ticket
	}

	/// Ticket identity prevents a stale cancellation or deadline from taking another RPC.
	@discardableResult
	public func cancel(_ ticket: Ticket, error: any Error = CancellationError()) -> Bool {
		guard let pending = take(ticket) else { return false }
		pending.timer?.cancel()
		pending.continuation.resume(throwing: error)
		return true
	}

	/// Called on the host executor. A stale expiry never invokes its diagnostic factory.
	@discardableResult
	public func expire(_ ticket: Ticket, makeError: () -> any Error) -> Bool {
		guard let pending = take(ticket) else { return false }
		pending.timer?.cancel()
		pending.continuation.resume(throwing: makeError())
		return true
	}

	private func contains(_ ticket: Ticket) -> Bool {
		state.withLock { $0.pending[ticket.id.storageKey]?.ticket == ticket }
	}

	public func failAll(with error: any Error) {
		let pending = drain()
		for request in pending {
			request.timer?.cancel()
			request.continuation.resume(throwing: error)
		}
	}

	public var pendingMethods: [String] {
		state.withLock { $0.pending.values.map(\.ticket.method).sorted() }
	}

	private func take(_ ticket: Ticket) -> Pending? {
		state.withLock { state in
			guard state.pending[ticket.id.storageKey]?.ticket == ticket else { return nil }
			return state.pending.removeValue(forKey: ticket.id.storageKey)
		}
	}
	private func drain() -> [Pending] {
		state.withLock { state in
			let pending = Array(state.pending.values)
			state.pending.removeAll()
			return pending
		}
	}
	deinit {
		for request in drain() {
			request.timer?.cancel()
			request.continuation.resume(throwing: StoreError.closed)
		}
	}
}
