import Foundation
import AgentClaudeProtocol
import AgentRuntimeKit

/// Actor-confined native permission ownership. Host policy determines presentation
/// or automatic approval; no tool inventory, app settings or authorization policy
/// is inferred here. Writes and observations are synchronous owner-executor ports.
public final class ClaudePermissionEngine {
	public struct Ticket: Hashable, Sendable {
		public let requestID: String
		fileprivate let key: Data
		fileprivate let scope: UUID
		fileprivate let nonce: UUID
	}
	public enum Disposition: Sendable { case present(AgentApprovalRequest), allowOnce }
	public enum ReplyKind: Sendable { case automatic, decision(AgentApprovalDecision), unsupported(String) }
	public enum Event: Sendable {
		case requested(AgentApprovalRequest, Ticket)
		case willReply(Ticket, ReplyKind, response: ClaudeProtocolJSONObject?)
	}
	private enum Stage { case deciding, pending, replying }
	private struct Entry {
		let ticket: Ticket
		let request: ClaudeNativeProtocolCodec.ControlRequest
		var stage: Stage
	}
	private var scope = UUID()
	private var accepting = true
	private var entries: [Data: Entry] = [:]
	public init() {}
	public var pendingRequestIDs: [String] {
		entries.values.filter { $0.stage == .pending }.map(\.ticket.requestID).sorted()
	}
	public func ticket(for requestID: String) -> Ticket? {
		guard let entry = entries[Data(requestID.utf8)], entry.stage == .pending else { return nil }
		return entry.ticket
	}
	/// Retires all tickets without fabricating wire replies or presentation events.
	/// The host chooses its session teardown UI policy, as in the native controller.
	public func retire() { accepting = false; scope = UUID(); entries.removeAll() }
	public func beginScope() { retire(); accepting = true }

	@discardableResult
	public func receive(_ request: ClaudeNativeProtocolCodec.ControlRequest,
		policy: (ClaudeNativeProtocolCodec.ControlRequest) -> Disposition,
		write: (Data) throws -> Void, observe: (Event) -> Void) throws -> Bool {
		let key = Data(request.requestID.utf8)
		guard accepting, entries[key] == nil else { return false }
		let ticket = Ticket(requestID: request.requestID, key: key, scope: scope, nonce: UUID())
		entries[key] = Entry(ticket: ticket, request: request, stage: .deciding)
		defer { if isCurrent(ticket), entries[key]?.stage == .deciding { entries[key] = nil } }
		guard request.subtype == "can_use_tool" else {
			return try reply(ticket, kind: .unsupported(request.subtype), response: nil, write: write, observe: observe)
		}
		let disposition = policy(request)
		guard isCurrent(ticket) else { return false }
		switch disposition {
		case .present(let approval):
			entries[key]?.stage = .pending
			observe(.requested(approval, ticket)); return true
		case .allowOnce:
			return try reply(ticket, kind: .automatic,
				response: Self.allowResponse(request.request, includeUpdatedPermissions: false), write: write, observe: observe)
		}
	}
	@discardableResult
	public func respond(_ ticket: Ticket, decision: AgentApprovalDecision,
		write: (Data) throws -> Void, observe: (Event) -> Void) throws -> Bool {
		guard isCurrent(ticket), let entry = entries[ticket.key], entry.stage == .pending else { return false }
		return try reply(ticket, kind: .decision(decision), response: Self.response(decision, request: entry.request.request),
			write: write, observe: observe)
	}
	@discardableResult
	public func cancel(_ ticket: Ticket) -> Bool {
		guard isCurrent(ticket), entries[ticket.key]?.stage == .pending else { return false }
		entries[ticket.key] = nil; return true
	}
	private func isCurrent(_ ticket: Ticket) -> Bool {
		accepting && ticket.scope == scope && entries[ticket.key]?.ticket == ticket
	}
	private func reply(_ ticket: Ticket, kind: ReplyKind, response: ClaudeProtocolJSONObject?,
		write: (Data) throws -> Void, observe: (Event) -> Void) throws -> Bool {
		guard isCurrent(ticket) else { return false }
		entries[ticket.key]?.stage = .replying
		defer { if isCurrent(ticket) { entries[ticket.key] = nil } }
		do {
			let data: Data
			if case .unsupported(let subtype) = kind {
				data = try ClaudeNativeProtocolCodec.encodeControlResponseError(requestID: ticket.requestID,
					error: "Unsupported control request subtype: \(subtype)")
			} else { data = try ClaudeNativeProtocolCodec.encodeControlResponseSuccess(requestID: ticket.requestID, response: response) }
			observe(.willReply(ticket, kind, response: response))
			guard isCurrent(ticket) else { return false }
			try write(data)
			return isCurrent(ticket)
		} catch {
			guard isCurrent(ticket) else { return false }
			throw error
		}
	}
	public static func response(_ decision: AgentApprovalDecision, request: ClaudeProtocolJSONObject) throws -> ClaudeProtocolJSONObject {
		switch decision {
		case .accept: return try allowResponse(request, includeUpdatedPermissions: false)
		case .acceptForSession, .acceptWithExecpolicyAmendment: return try allowResponse(request, includeUpdatedPermissions: true)
		case .decline: return try .init(object: ["behavior": "deny", "message": "Permission denied by user."])
		case .cancel: return try .init(object: ["behavior": "deny", "message": "Permission cancelled by user.", "interrupt": true])
		}
	}
	public static func allowResponse(_ request: ClaudeProtocolJSONObject, includeUpdatedPermissions: Bool) throws -> ClaudeProtocolJSONObject {
		let input = try request.dictionary()
		var payload: [String: Any] = ["behavior": "allow", "updatedInput": input["input"] as? [String: Any] ?? [:]]
		if includeUpdatedPermissions, let suggestions = input["permission_suggestions"] as? [[String: Any]], !suggestions.isEmpty {
			payload["updatedPermissions"] = suggestions
		}
		if let id = (input["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
			payload["toolUseID"] = id
		}
		return try .init(object: payload)
	}
}
