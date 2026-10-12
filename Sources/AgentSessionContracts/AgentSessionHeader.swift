import Foundation
import AgentRuntimeKit

/// Lightweight metadata decode deliberately does not materialize items, transcript or usage rows.
public struct AgentSessionHeader: Decodable, Sendable {
	public let id: UUID
	public let serializationVersion: Int?
	public let workspaceID: UUID?
	public let composeTabID: UUID?
	public let name: String
	public let savedAt: Date
	public let itemCount: Int?
	public let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
	public let lastUserMessageAt: Date?
	public let agentKind: String?
	public let agentModel: String?
	public let agentReasoningEffort: String?
	public let lastRunState: String?
	public let providerSessionID: String?
	public let geminiACPResumeMetadata: GeminiACPResumeMetadata?
	public let autoEditEnabled: Bool
	public let codexConversationID: String?
	public let codexRolloutPath: String?
	public let codexModel: String?
	public let codexReasoningEffort: String?
	public let codexServiceTier: String?
	public let codexContextWindow: Int?
	public let codexLastTotalTokens: Int?
	public let codexTotalTotalTokens: Int?
	public let codexMcpSessionKey: String?
	public let parentSessionID: UUID?
	public let pendingHandoffPayload: String?
	public let pendingHandoffCreatedAt: Date?
	public let pendingHandoffSourceItemID: UUID?
	public let pendingHandoffDefersProviderLockUntilSend: Bool?
	public let isMCPOriginated: Bool?
}
