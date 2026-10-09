import Foundation

/// Injectable execution surface for provider adapters. Values are byte streams
/// and exit metadata; provider protocol interpretation belongs above this layer.
public protocol AgentCLIExecuting: Sendable {
	func run(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?,
		additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AgentCLIRunner.Result
	func runStreaming(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?,
		additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>
	func cancelAll() async
}

extension AgentCLIRunner: AgentCLIExecuting {}
