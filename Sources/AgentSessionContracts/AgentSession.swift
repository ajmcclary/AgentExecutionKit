import Foundation
import AgentRuntimeKit
import AgentUsage

public struct GeminiACPResumeMetadata: Codable, Equatable, Sendable {
	public var runtimeSessionID: String?
	public var loadSessionID: String?
	public var loadSessionIDVerifiedAt: Date?

	public init(
		runtimeSessionID: String? = nil,
		loadSessionID: String? = nil,
		loadSessionIDVerifiedAt: Date? = nil
	) {
		self.runtimeSessionID = runtimeSessionID
		self.loadSessionID = loadSessionID
		self.loadSessionIDVerifiedAt = loadSessionIDVerifiedAt
	}
}

public struct AgentSession: Codable, Identifiable, Sendable {
	public static let currentSerializationVersion = 4
	public static let legacyUnversionedSerializationVersion = 0

	public let id: UUID
	public var serializationVersion: Int
	public var workspaceID: UUID?
	public var composeTabID: UUID?
	public var name: String
	public var savedAt: Date
	public var fileURL: URL?
	
	/// Last user interaction timestamp (user message or answered question)
	public var lastUserMessageAt: Date?
	
	/// Mutable full-detail working suffix retained for runtime compatibility and legacy decode.
	/// Newly persisted sessions store this empty and rebuild it from the transcript when needed.
	public var items: [AgentChatItemPersist]
	
	/// Structured transcript source of truth. Compacted turns may retain only summary shells.
	public var transcript: AgentTranscript?
	
	/// Optional lightweight item count for sessions where transcript/items are unloaded.
	public var itemCount: Int?

	/// Snapshot of canonical vs default-presented transcript counts.
	public var transcriptProjectionCounts: AgentTranscriptProjectionCounts?
	
	/// Agent kind used for this session (e.g., "claudeCode", "codexExec", "gemini")
	public var agentKind: String?
	
	/// Model used for this session (e.g., "sonnet", "opus", "codexMedium")
	public var agentModel: String?

	/// User-selected reasoning effort (Codex-only)
	public var agentReasoningEffort: String?
	
	/// State of the last run
	public var lastRunState: String?
	
	/// Provider-specific resumable session identifier (e.g., Claude CLI session_id)
	/// Used to resume conversations with --resume instead of replaying history
	public var providerSessionID: String?
	public var geminiACPResumeMetadata: GeminiACPResumeMetadata?
	public var autoEditEnabled: Bool

	/// Persisted per-turn token usage for non-Codex providers (Claude/Gemini).
	/// Used to rebuild context usage after reopen/resume when tool payloads are pruned.
	public var providerTokenUsageByTurn: [AgentTokenUsagePersist]

	/// Codex native session identifiers (v2 thread and rollout path)
	public var codexConversationID: String?
	public var codexRolloutPath: String?

	/// Codex native session metadata
	public var codexModel: String?
	public var codexReasoningEffort: String?
	public var codexServiceTier: String?
	public var codexContextWindow: Int?
	public var codexLastTotalTokens: Int?
	public var codexTotalTotalTokens: Int?
	public var codexMcpSessionKey: String?

	/// Parent session ID for thread nesting (child sessions spawned from another session)
	public var parentSessionID: UUID?

	/// Whether this session was originally created by an MCP client (vs the user in the UI).
	/// Used to scope cleanup operations to MCP-originated sessions only.
	public var isMCPOriginated: Bool

	/// Pending handoff payload (injected into the provider-facing text on the destination tab's
	/// first user send, then cleared). Persisted so it survives close/reopen.
	public var pendingHandoffPayload: String?
	public var pendingHandoffCreatedAt: Date?
	public var pendingHandoffSourceItemID: UUID?
	public var pendingHandoffDefersProviderLockUntilSend: Bool
	
	public init(
		id: UUID = UUID(),
		serializationVersion: Int = AgentSession.currentSerializationVersion,
		workspaceID: UUID? = nil,
		composeTabID: UUID? = nil,
		name: String = "Agent Session",
		savedAt: Date = Date(),
		fileURL: URL? = nil,
		items: [AgentChatItemPersist] = [],
		transcript: AgentTranscript? = nil,
		itemCount: Int? = nil,
		transcriptProjectionCounts: AgentTranscriptProjectionCounts? = nil,
		lastUserMessageAt: Date? = nil,
		agentKind: String? = nil,
		agentModel: String? = nil,
		agentReasoningEffort: String? = nil,
		lastRunState: String? = nil,
		providerSessionID: String? = nil,
		geminiACPResumeMetadata: GeminiACPResumeMetadata? = nil,
		autoEditEnabled: Bool = true,
		providerTokenUsageByTurn: [AgentTokenUsagePersist] = [],
		codexConversationID: String? = nil,
		codexRolloutPath: String? = nil,
		codexModel: String? = nil,
		codexReasoningEffort: String? = nil,
		codexServiceTier: String? = nil,
		codexContextWindow: Int? = nil,
		codexLastTotalTokens: Int? = nil,
		codexTotalTotalTokens: Int? = nil,
		codexMcpSessionKey: String? = nil,
		parentSessionID: UUID? = nil,
		pendingHandoffPayload: String? = nil,
		pendingHandoffCreatedAt: Date? = nil,
		pendingHandoffSourceItemID: UUID? = nil,
		pendingHandoffDefersProviderLockUntilSend: Bool = false,
		isMCPOriginated: Bool = false
	) {
		self.id = id
		self.serializationVersion = serializationVersion
		self.workspaceID = workspaceID
		self.composeTabID = composeTabID
		self.name = name
		self.savedAt = savedAt
		self.fileURL = fileURL
		self.items = items
		self.transcript = transcript
		self.itemCount = itemCount
		self.transcriptProjectionCounts = transcriptProjectionCounts
		self.lastUserMessageAt = lastUserMessageAt
		self.agentKind = agentKind
		self.agentModel = agentModel
		self.agentReasoningEffort = agentReasoningEffort
		self.lastRunState = lastRunState
		self.providerSessionID = providerSessionID
		self.geminiACPResumeMetadata = geminiACPResumeMetadata
		self.autoEditEnabled = autoEditEnabled
		self.providerTokenUsageByTurn = providerTokenUsageByTurn
		self.codexConversationID = codexConversationID
		self.codexRolloutPath = codexRolloutPath
		self.codexModel = codexModel
		self.codexReasoningEffort = codexReasoningEffort
		self.codexServiceTier = codexServiceTier
		self.codexContextWindow = codexContextWindow
		self.codexLastTotalTokens = codexLastTotalTokens
		self.codexTotalTotalTokens = codexTotalTotalTokens
		self.codexMcpSessionKey = codexMcpSessionKey
		self.parentSessionID = parentSessionID
		self.pendingHandoffPayload = pendingHandoffPayload
		self.pendingHandoffCreatedAt = pendingHandoffCreatedAt
		self.pendingHandoffSourceItemID = pendingHandoffSourceItemID
		self.pendingHandoffDefersProviderLockUntilSend = pendingHandoffDefersProviderLockUntilSend
		self.isMCPOriginated = isMCPOriginated
	}
	
	enum CodingKeys: String, CodingKey {
		case id
		case serializationVersion
		case workspaceID
		case composeTabID
		case name
		case savedAt
		case fileURL
		case items
		case transcript
		case itemCount
		case transcriptProjectionCounts
		case lastUserMessageAt
		case agentKind
		case agentModel
		case agentReasoningEffort
		case lastRunState
		case providerSessionID
		case geminiACPResumeMetadata
		case autoEditEnabled
		case providerTokenUsageByTurn
		case codexConversationID
		case codexRolloutPath
		case codexModel
		case codexReasoningEffort
		case codexServiceTier
		case codexContextWindow
		case codexLastTotalTokens
		case codexTotalTotalTokens
		case codexMcpSessionKey
		case parentSessionID
		case pendingHandoffPayload
		case pendingHandoffCreatedAt
		case pendingHandoffSourceItemID
		case pendingHandoffDefersProviderLockUntilSend
		case isMCPOriginated
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		
		id = try container.decode(UUID.self, forKey: .id)
		serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
			?? Self.legacyUnversionedSerializationVersion
		workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
		composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
		name = try container.decode(String.self, forKey: .name)
		savedAt = try container.decode(Date.self, forKey: .savedAt)
		fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
		items = try container.decodeIfPresent([AgentChatItemPersist].self, forKey: .items) ?? []
		transcript = try container.decodeIfPresent(AgentTranscript.self, forKey: .transcript)
		itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
		transcriptProjectionCounts = try container.decodeIfPresent(AgentTranscriptProjectionCounts.self, forKey: .transcriptProjectionCounts)
		lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
		agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
		agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
		agentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffort)
		lastRunState = try container.decodeIfPresent(String.self, forKey: .lastRunState)
		providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
		geminiACPResumeMetadata = try container.decodeIfPresent(GeminiACPResumeMetadata.self, forKey: .geminiACPResumeMetadata)
		autoEditEnabled = try container.decode(Bool.self, forKey: .autoEditEnabled)
		// Bound the collection AT the decode boundary (eleventh round finding 7;
		// twelfth round finding 3): the eleventh round decoded the COMPLETE array and
		// then pruned it, so an arbitrarily large persisted array was still fully
		// materialized. The streaming decode folds overflow row-by-row and never holds
		// more than a bounded typed-row buffer. (The Foundation JSON tree the decoder
		// parses first remains proportional to file size; what is bounded here is the
		// typed `[AgentTokenUsagePersist]` materialization this finding names.)
		providerTokenUsageByTurn = try AgentTokenUsagePersist.decodeBoundedRetained(
			from: container,
			forKey: .providerTokenUsageByTurn,
			probe: decoder.userInfo[AgentUsageDecodeProbe.userInfoKey] as? AgentUsageDecodeProbe
		)
		codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
		codexRolloutPath = try container.decodeIfPresent(String.self, forKey: .codexRolloutPath)
		codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
		codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort)
		codexServiceTier = try container.decodeIfPresent(String.self, forKey: .codexServiceTier)
		codexContextWindow = try container.decodeIfPresent(Int.self, forKey: .codexContextWindow)
		codexLastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexLastTotalTokens)
		codexTotalTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexTotalTotalTokens)
		codexMcpSessionKey = try container.decodeIfPresent(String.self, forKey: .codexMcpSessionKey)
		parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
		pendingHandoffPayload = try container.decodeIfPresent(String.self, forKey: .pendingHandoffPayload)
		pendingHandoffCreatedAt = try container.decodeIfPresent(Date.self, forKey: .pendingHandoffCreatedAt)
		pendingHandoffSourceItemID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffSourceItemID)
		self.pendingHandoffDefersProviderLockUntilSend = try container.decodeIfPresent(Bool.self, forKey: .pendingHandoffDefersProviderLockUntilSend) ?? false
		self.isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated) ?? false
	}
	
	/// Coalesces whitespace and falls back to "Agent Session" when empty.
	/// This display-name normalization performs no preference or identity lookup.
	public static func validatedName(_ raw: String) -> String {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		let collapsed = trimmed
			.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
		return collapsed.isEmpty ? "Agent Session" : collapsed
	}
}

public extension AgentSession {
    /// A payload-free list record still carries an explicit item-count hint.
    var isListStub: Bool { items.isEmpty && transcript == nil && itemCount != nil }
}
