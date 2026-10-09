import Foundation
import AIClientKit

public struct HeadlessAgentMessage: Sendable, Equatable {
    /// System prompt / instructions for the agent
    public var systemPrompt: String

    /// The user's message / task
    public var userMessage: String

    /// Optional provider-specific session ID for resuming conversations
    /// Used by Claude CLI to resume with --resume <session-id> instead of replaying history
    public var resumeSessionID: String?

    public init(systemPrompt: String = "", userMessage: String, resumeSessionID: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.resumeSessionID = resumeSessionID
    }
}

public protocol HeadlessAgentProviding: Sendable {
	func streamAgentMessage(_ message: HeadlessAgentMessage, runID: UUID?) async throws -> AsyncThrowingStream<AIStreamResult, Error>
	func dispose() async
}
