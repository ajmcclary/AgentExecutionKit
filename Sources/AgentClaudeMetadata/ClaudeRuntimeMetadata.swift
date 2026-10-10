import Foundation
import AgentClaudeProtocol
import AgentClaudeEvents

/// Actor-confined native metadata aggregation. Observation reset preserves the
/// normalized provider session ID, matching native reconnect behavior.
public final class ClaudeRuntimeMetadata {
	public struct Token: Equatable, Sendable { fileprivate let id: UUID }
	public private(set) var token = Token(id: UUID())
	public private(set) var sessionID: String?
	private var initializeResponse: ClaudeRuntimeInitStatus.InitializeResponseSnapshot?
	private var tools: [String] = []
	private var statuses: [String: String] = [:]
	private var lastPublished: ClaudeRuntimeInitStatus?
	public init() {}
	public var snapshot: ClaudeRuntimeInitStatus {
		.init(sessionID: sessionID, tools: tools, mcpServerStatuses: statuses, initializeResponse: initializeResponse)
	}
	public func resetObservations() {
		token = Token(id: UUID()); initializeResponse = nil; tools = []; statuses = [:]; lastPublished = nil
	}
	public func recordSessionID(_ candidate: String?, for source: Token? = nil, emit: (ClaudeRuntimeInitStatus) -> Void) {
		guard source == nil || source == token,
			let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
		let changed = sessionID != value; sessionID = value
		if changed { publishIfChanged(emit: emit) }
	}
	/// Preserve native ordering: the changed session identity is published before
	/// the control-response snapshot is stored, which is published at readiness.
	@discardableResult
	public func recordInitialize(_ response: ClaudeProtocolJSONObject, for source: Token? = nil,
		emit: (ClaudeRuntimeInitStatus) -> Void) throws -> ClaudeRuntimeInitStatus.InitializeResponseSnapshot? {
		guard source == nil || source == token else { return nil }
		let stamp = token
		let raw = try response.dictionary()
		recordSessionID(raw["session_id"] as? String, emit: emit)
		guard stamp == token else { return nil }
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(response); initializeResponse = parsed; return parsed
	}
	@discardableResult
	public func recordSystemInit(_ payload: ClaudeProtocolJSONObject, for source: Token? = nil,
		observe: (ClaudeMetadataCodec.SystemInitFields) -> Void, emit: (ClaudeRuntimeInitStatus) -> Void) throws -> Bool {
		guard source == nil || source == token, let fields = try ClaudeMetadataCodec.parseSystemInit(payload) else { return false }
		let stamp = token; tools = fields.tools; statuses = fields.mcpStatuses
		observe(fields)
		guard stamp == token else { return false }
		publishIfChanged(emit: emit); return true
	}
	public func publishIfChanged(emit: (ClaudeRuntimeInitStatus) -> Void) {
		let value = snapshot; guard value != lastPublished else { return }
		lastPublished = value; emit(value)
	}
}
