import Foundation
import AgentClaudeProtocol

/// Actor-confined native control channel. The host supplies transport availability,
/// writes, observations, deadline delivery and error vocabulary. Caller cancellation
/// deliberately does not cancel a protocol request: the native interrupt command and
/// transport teardown remain authoritative, matching Claude's existing controller.
public final class ClaudeControlChannel {
	public struct Errors: Sendable {
		public let unavailable: @Sendable () -> any Error
		public let invalidResponse: @Sendable (String) -> any Error
		public let timedOut: @Sendable (String) -> any Error
		public init(unavailable: @escaping @Sendable () -> any Error,
			invalidResponse: @escaping @Sendable (String) -> any Error,
			timedOut: @escaping @Sendable (String) -> any Error) {
			self.unavailable = unavailable; self.invalidResponse = invalidResponse; self.timedOut = timedOut
		}
	}
	public struct Ticket: Hashable, Sendable {
		public let requestID: String
		let token: UUID
	}
	public struct Deadline: Sendable {
		public let duration: Duration
		/// Deliver expiry on the owner executor, then call expire. Replies and deadlines
		/// retain the host's actor ordering; no timeout task captures channel state.
		public let onExpiry: @Sendable (Ticket) async -> Void
		public init(duration: Duration, onExpiry: @escaping @Sendable (Ticket) async -> Void) {
			self.duration = duration; self.onExpiry = onExpiry
		}
	}
	public typealias Sleep = @Sendable (Duration) async throws -> Void
	public enum ChannelError: Error { case identifiersExhausted, released }
	private let store: ClaudeControlRequestStore
	private let errors: Errors
	public init(requestIDPrefix: String, errors: Errors,
		sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
		store = .init(prefix: requestIDPrefix, sleep: sleep); self.errors = errors
	}
	public var pendingRequestIDs: [String] { store.pendingRequestIDs }

	public func request(_ request: ClaudeProtocolJSONObject, deadline: Deadline? = nil,
		isAvailable: () -> Bool, observe: (Ticket, Bool) -> Void, write: (Data) throws -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeProtocolJSONObject {
		guard isAvailable() else { throw errors.unavailable() }
		let ticket = try store.nextTicket()
		let payload = try ClaudeNativeProtocolCodec.encodeControlRequest(requestID: ticket.requestID, request: request)
		observe(ticket, true)
		return try await withCheckedThrowingContinuation { continuation in
			store.register(ticket, continuation: continuation, deadline: deadline)
			do { try write(payload) }
			catch { store.fail(ticket, with: error) }
		}
	}
	public func notify(_ request: ClaudeProtocolJSONObject, isAvailable: () -> Bool,
		observe: (Ticket, Bool) -> Void, write: (Data) throws -> Void) throws {
		guard isAvailable() else { throw errors.unavailable() }
		let ticket = try store.nextTicket()
		let payload = try ClaudeNativeProtocolCodec.encodeControlRequest(requestID: ticket.requestID, request: request)
		observe(ticket, false)
		try write(payload)
	}

	/// Only a matched response is observed or recovers permissions. Remove before all
	/// call-outs. Error completion precedes recovery, preserving native event ordering.
	@discardableResult
	public func receive(_ response: ClaudeNativeProtocolCodec.ControlResponse,
		observe: (ClaudeNativeProtocolCodec.ControlResponse) -> Void,
		recoverPermission: (ClaudeNativeProtocolCodec.ControlRequest) -> Void) -> Bool {
		guard let pending = store.take(response.requestID) else { return false }
		pending.timer?.cancel()
		observe(response)
		switch response.subtype {
		case "success":
			// The codec guarantees object validity; nil means the legacy empty object.
			pending.continuation.resume(returning: response.response ?? ClaudeControlRequestStore.emptyObject)
		case "error":
			pending.continuation.resume(throwing: errors.invalidResponse(response.error ?? "Unknown Claude control error"))
			for raw in response.pendingPermissionRequests {
				guard let value = try? raw.dictionary(), let id = value["request_id"] as? String,
					let request = value["request"] as? [String: Any],
					let object = try? ClaudeProtocolJSONObject(object: request) else { continue }
				recoverPermission(.init(requestID: id, request: object, subtype: request["subtype"] as? String ?? ""))
			}
		default:
			pending.continuation.resume(throwing: errors.invalidResponse("Unsupported subtype: \(response.subtype)"))
		}
		return true
	}
	@discardableResult
	public func expire(_ ticket: Ticket) -> Bool { store.fail(ticket, makeError: { errors.timedOut(ticket.requestID) }) }
	public func failAll(with error: any Error) { store.failAll(with: error) }
}
