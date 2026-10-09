import Foundation
import AgentCLIExecution
import AIClientKit

public struct CodexExecToolPolicy: Sendable {
	public let isExternallyTrackedToolName: @Sendable (String) -> Bool
	public let isExternallyTrackedServer: @Sendable (String) -> Bool
	public init(isExternallyTrackedToolName: @escaping @Sendable (String) -> Bool,
		isExternallyTrackedServer: @escaping @Sendable (String) -> Bool) {
		self.isExternallyTrackedToolName = isExternallyTrackedToolName
		self.isExternallyTrackedServer = isExternallyTrackedServer
	}
}

public struct CodexExecRunContext: Sendable {
	public let id: UUID
	public let runID: UUID
	public let arguments: [String]
	public let execution: any AgentCLIExecuting
	public init(id: UUID = UUID(), runID: UUID, arguments: [String], execution: any AgentCLIExecuting) {
		self.id = id; self.runID = runID; self.arguments = arguments; self.execution = execution
	}
}

public struct CodexExecHostServices: Sendable {
	public let validate: @Sendable () throws -> Void
	public let prepare: @Sendable (UUID?) async throws -> CodexExecRunContext
	public let startObservation: @Sendable (CodexExecRunContext, @escaping @Sendable (AIStreamResult) -> Void) async -> Void
	public let cleanup: @Sendable (CodexExecRunContext) async -> Void
	public let recordBrokenServer: @Sendable (String) async -> Void
	public let modelUnavailableError: @Sendable (String) -> any Error
	public let diagnostics: @Sendable (String) -> Void
	public init(validate: @escaping @Sendable () throws -> Void,
		prepare: @escaping @Sendable (UUID?) async throws -> CodexExecRunContext,
		startObservation: @escaping @Sendable (CodexExecRunContext, @escaping @Sendable (AIStreamResult) -> Void) async -> Void,
		cleanup: @escaping @Sendable (CodexExecRunContext) async -> Void,
		recordBrokenServer: @escaping @Sendable (String) async -> Void,
		modelUnavailableError: @escaping @Sendable (String) -> any Error,
		diagnostics: @escaping @Sendable (String) -> Void) {
		self.validate = validate; self.prepare = prepare; self.startObservation = startObservation; self.cleanup = cleanup
		self.recordBrokenServer = recordBrokenServer; self.modelUnavailableError = modelUnavailableError; self.diagnostics = diagnostics
	}
}

enum CodexExecJSONFormatting {
	static func prettyString(from object: Any) -> String? {
		guard JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
		return String(data: data, encoding: .utf8)
	}
}
