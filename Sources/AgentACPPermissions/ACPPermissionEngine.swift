import Foundation
import AgentACPRPC
import AgentACPProtocol
import AgentRuntimeKit

/// Synchronous approval owner confined to one actor. Tickets expire at settlement
/// and cannot act on another request even when its wire ID is reused.
public final class ACPPermissionEngine {
	public struct Ticket: Hashable, Sendable {
		public let requestID: AgentApprovalRequestID
		fileprivate let key: Data
		fileprivate let nonce: UUID
		fileprivate let scope: UInt64
	}
	public enum Event: Sendable {
		case requested(AgentApprovalRequest, Ticket)
		case resolved(AgentApprovalRequestID)
		case cancelled(AgentApprovalRequestID)
		case decisionFailed(any Error)
		case automaticallyApproved(ACPPermissionRequest, optionID: String)
		case automaticApprovalFailed(ACPPermissionRequest, any Error)
		case info(String), log(String)
	}
	private struct Pending {
		let ticket: Ticket
		let validated: ACPPermissionRequest
		let approval: AgentApprovalRequest
	}
	private var scope: UInt64 = 0
	private var accepting = true
	private var pending: [Data: Pending] = [:]
	private var order: [Data] = []
	private var presented: Data?
	private var claims: [UUID: Pending] = [:]
	private var claimOrder: [UUID] = []
	private var automaticReservations = Set<Data>()
	public init() {}
	public var pendingStorageKeys: [String] { pending.values.map(\.validated.storageKey).sorted() }

	/// Prelude requests can share the first turn. After settlement, a new turn must
	/// explicitly reopen admission; late frames between turns receive a refusal.
	public func beginScope() { accepting = true }
	public func ticket(for requestID: AgentApprovalRequestID) -> Ticket? {
		guard case .acp(let key) = requestID else { return nil }
		return pending[Data(key.utf8)]?.ticket
	}
	public func receive(id: ACPRequestID, params: ACPJSONObject, boundSessionID: String?,
		policy: ACPPermissionPolicy, makeApproval: (ACPPermissionRequest) -> AgentApprovalRequest,
		write: (ACPJSONObject) throws -> Void, onEvent: (Event) -> Void) {
		let key = Data(id.storageKey.utf8)
		// Outstanding ownership wins even when the repeated payload is malformed.
		guard pending[key] == nil, !automaticReservations.contains(key),
			!claims.values.contains(where: { $0.ticket.key == key }) else {
			onEvent(.info("Dropped duplicate ACP permission request id; the outstanding request is unchanged.")); return
		}
		let validated: ACPPermissionRequest
		do {
			guard accepting else { throw ACPPermissionRefusal.retiredScope }
			validated = try ACPPermissionValidation.validate(id: id, params: params.dictionary(),
				boundSessionID: boundSessionID, policy: policy).get()
		} catch {
			let refusal = (error as? ACPPermissionRefusal) ?? .malformedToolCall
			onEvent(.info("Refused ACP permission request: \(refusal.message)"))
			do { try write(.init(object: ["jsonrpc": "2.0", "id": id.jsonValue, "error": ["code": -32602, "message": refusal.message]])) }
			catch { onEvent(.log("Failed to refuse ACP permission request: \(error.localizedDescription)")) }
			return
		}
		let stamp = scope
		if let preferences = policy.automatic,
			let option = ACPPermissionPolicy.optionID(for: validated.options, preferences: preferences) {
			automaticReservations.insert(key)
			defer { automaticReservations.remove(key) }
			do {
				try write(Self.response(id: id, optionID: option))
				if scope == stamp, accepting { onEvent(.automaticallyApproved(validated, optionID: option)) }
				return
			} catch {
				guard scope == stamp, accepting else { return }
				onEvent(.automaticApprovalFailed(validated, error))
			}
		}
		guard scope == stamp, accepting, pending[key] == nil else { return }
		let approval = makeApproval(validated)
		guard scope == stamp, accepting, pending[key] == nil else { return }
		let ticket = Ticket(requestID: .acp(validated.storageKey), key: key, nonce: UUID(), scope: scope)
		pending[key] = .init(ticket: ticket, validated: validated, approval: approval)
		order.append(key); presentNext(onEvent)
	}
	public func respond(_ ticket: Ticket, decision: AgentApprovalDecision, policy: ACPPermissionPolicy,
		write: (ACPJSONObject) throws -> Void, onEvent: (Event) -> Void) {
		guard ticket.scope == scope, accepting, let request = pending[ticket.key], request.ticket == ticket else { return }
		pending[ticket.key] = nil; order.removeAll { $0 == ticket.key }
		claims[ticket.nonce] = request; claimOrder.append(ticket.nonce)
		if presented == ticket.key { presented = nil; presentNext(onEvent) }
		guard claims[ticket.nonce] != nil, ticket.scope == scope, accepting else { return }
		do {
			let option = policy.optionID(for: request.validated.options, decision: decision)
			try write(Self.response(id: request.validated.rpcID, optionID: option))
			guard removeClaim(ticket.nonce) != nil, ticket.scope == scope, accepting else { return }
			onEvent(.resolved(request.approval.requestID))
		} catch {
			guard removeClaim(ticket.nonce) != nil, ticket.scope == scope, accepting else { return }
			onEvent(.cancelled(request.approval.requestID))
			guard ticket.scope == scope, accepting else { return }
			onEvent(.decisionFailed(error))
		}
	}
	/// Claims have reserved a wire reply; settlement cancels only their UI lifecycle.
	/// Presented/queued requests receive cancellation replies when the transport is live.
	public func settle(attemptWireResponses: Bool, write: (ACPJSONObject) throws -> Void, onEvent: (Event) -> Void) {
		let inFlight = claimOrder.compactMap { claims[$0] }
		var requests: [Pending] = []
		if let presented, let visible = pending[presented] { requests.append(visible) }
		for key in order where key != presented { if let request = pending[key] { requests.append(request) } }
		accepting = false; scope &+= 1
		pending.removeAll(); order.removeAll(); presented = nil; claims.removeAll(); claimOrder.removeAll()
		for request in inFlight { onEvent(.cancelled(request.approval.requestID)) }
		for request in requests {
			if attemptWireResponses {
				do { try write(Self.response(id: request.validated.rpcID, optionID: nil)) }
				catch { onEvent(.log("Failed to cancel ACP permission request \(request.validated.rpcID.displayValue): \(error.localizedDescription)")) }
			}
			onEvent(.cancelled(request.approval.requestID))
		}
	}
	private func removeClaim(_ nonce: UUID) -> Pending? {
		claimOrder.removeAll { $0 == nonce }; return claims.removeValue(forKey: nonce)
	}
	private func presentNext(_ onEvent: (Event) -> Void) {
		guard presented == nil else { return }
		while !order.isEmpty {
			let key = order.removeFirst()
			guard let request = pending[key] else { continue }
			presented = key; onEvent(.requested(request.approval, request.ticket)); return
		}
	}
	public static func response(id: ACPRequestID, optionID: String?) throws -> ACPJSONObject {
		let result: [String: Any]
		if let optionID, !optionID.isEmpty { result = ["outcome": ["outcome": "selected", "optionId": optionID]] }
		else { result = ["outcome": ["outcome": "cancelled"]] }
		return try .init(object: ["jsonrpc": "2.0", "id": id.jsonValue, "result": result])
	}
}
