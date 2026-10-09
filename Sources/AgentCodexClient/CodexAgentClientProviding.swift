import Foundation
import AgentRuntimeKit
import CodexRuntimeKit

/// Injectable native Codex surface. JSON values and provider runtime events
/// cross the boundary without an external SDK or host application type.
public protocol CodexAgentClientProviding: Sendable {
	func startIfNeeded() async throws
	func stop() async
	func requestJSON(method: String, params: [String: CodexJSONValue]?, timeout: TimeInterval?) async throws -> [String: CodexJSONValue]
	func notifyJSON(method: String, params: [String: CodexJSONValue]?) async throws
	func respondJSONToServerRequest(id: CodexAppServerRequestID, result: [String: CodexJSONValue]) async throws
	func subscribeNotifications() async -> AsyncStream<CodexServerNotification>
	func subscribeServerRequests() async -> AsyncStream<CodexServerRequest>
	func listModels(limit: Int) async throws -> [CodexRemoteModel]
}

extension CodexAgentClient: CodexAgentClientProviding {
	public func notifyJSON(method: String, params: [String: CodexJSONValue]?) throws {
		try notify(method: method, params: params?.mapValues { $0.toAny() })
	}
	public func respondJSONToServerRequest(id: CodexAppServerRequestID, result: [String: CodexJSONValue]) throws {
		try respondToServerRequest(id: id, result: result.mapValues { $0.toAny() })
	}
}
