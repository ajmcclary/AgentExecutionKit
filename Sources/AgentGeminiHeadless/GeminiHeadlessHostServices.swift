import Foundation
import AgentCLIExecution
import AgentHeadlessContracts
import AIClientKit

/// A run-scoped executor and resolved launch inputs. The host owns executable,
/// credential, model, prompt, permission, and MCP configuration policy.
public struct GeminiHeadlessRunContext: Sendable {
	public let id: UUID
	public let runID: UUID
	public let arguments: [String]
	public let input: String
	public let additionalEnvironment: [String: String]
	public let additionalRemovedKeys: Set<String>
	public let execution: any AgentCLIExecuting
	public init(id: UUID = UUID(), runID: UUID, arguments: [String], input: String,
		additionalEnvironment: [String: String] = [:], additionalRemovedKeys: Set<String> = [],
		execution: any AgentCLIExecuting) {
		self.id = id; self.runID = runID; self.arguments = arguments; self.input = input
		self.additionalEnvironment = additionalEnvironment; self.additionalRemovedKeys = additionalRemovedKeys
		self.execution = execution
	}
}

public struct GeminiHeadlessHostServices: Sendable {
	public let prepare: @Sendable (HeadlessAgentMessage, UUID?) async throws -> GeminiHeadlessRunContext
	public let startObservation: @Sendable (GeminiHeadlessRunContext, @escaping @Sendable (AIStreamResult) -> Void) async -> Void
	public let cleanup: @Sendable (GeminiHeadlessRunContext) async -> Void
	public let diagnostics: @Sendable (String) -> Void
	public init(prepare: @escaping @Sendable (HeadlessAgentMessage, UUID?) async throws -> GeminiHeadlessRunContext,
		startObservation: @escaping @Sendable (GeminiHeadlessRunContext, @escaping @Sendable (AIStreamResult) -> Void) async -> Void,
		cleanup: @escaping @Sendable (GeminiHeadlessRunContext) async -> Void,
		diagnostics: @escaping @Sendable (String) -> Void = { _ in }) {
		self.prepare = prepare; self.startObservation = startObservation; self.cleanup = cleanup
		self.diagnostics = diagnostics
	}
}
