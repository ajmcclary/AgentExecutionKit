import Foundation
import AgentRuntimeKit

public enum AgentTranscriptAnchor: Hashable, Sendable {
    public var turnID: UUID {
        switch self {
        case .request(let id), .summary(let id), .groupedHistory(let id, _): return id
        case .activity(let id, _, _), .conclusion(let id, _): return id
        }
    }
	case request(turnID: UUID)
	case activity(turnID: UUID, spanID: UUID, activityID: UUID)
	case conclusion(turnID: UUID, activityID: UUID)
	case summary(turnID: UUID)
	case groupedHistory(turnID: UUID, spanID: UUID)
}

public enum AgentTranscriptProjectionProtection: Sendable, Equatable {
	case none
	case protectedTurn(UUID)

	public var protectedTurnID: UUID? {
		guard case .protectedTurn(let turnID) = self else { return nil }
		return turnID
	}
}

public enum AgentTranscriptRenderBlockKind: String, Sendable, Equatable {
	case request
	case activityCluster
	case groupedHistory
	case standaloneAssistant
	case standaloneTool
	case standaloneNote
	case middleSummary
	case conclusion
}

public enum AgentTranscriptBlockPresentation: String, Sendable, Equatable {
	case expanded
	case collapsed
}

public enum AgentTranscriptGroupedSectionKind: String, Sendable, Equatable {
	case assistant
	case tools
	case progress
	case notes
	case mixed
}

public struct AgentTranscriptGroupedSection: Identifiable, Sendable, Equatable {
	public let id: String
	public let kind: AgentTranscriptGroupedSectionKind
	public let title: String?
	public let icon: String?
	public let childBlocks: [AgentTranscriptRenderBlock]
	public let clusterSummary: AgentTranscriptClusterSummary?

	public init(
		id: String,
		kind: AgentTranscriptGroupedSectionKind,
		title: String? = nil,
		icon: String? = nil,
		childBlocks: [AgentTranscriptRenderBlock],
		clusterSummary: AgentTranscriptClusterSummary? = nil
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.icon = icon
		self.childBlocks = childBlocks
		self.clusterSummary = clusterSummary
	}
}

public struct AgentTranscriptGroupedHistory: Sendable, Equatable {
	public let summary: AgentTranscriptGroupedHistorySummary
	public let sections: [AgentTranscriptGroupedSection]

	public init(
		summary: AgentTranscriptGroupedHistorySummary,
		sections: [AgentTranscriptGroupedSection]
	) {
		self.summary = summary
		self.sections = sections
	}
}

public struct AgentTranscriptRenderBlock: Identifiable, Sendable, Equatable {
	public let id: String
	public let kind: AgentTranscriptRenderBlockKind
	public let turnID: UUID
	public let spanID: UUID?
	public let retentionTier: AgentTranscriptRetentionTier
	public let rows: [AgentChatItem]
	public let isArchived: Bool
	public let primaryAnchor: AgentTranscriptAnchor?
	public let anchorActivityID: UUID?
	public let activityIDs: [UUID]
	public let clusterSummary: AgentTranscriptClusterSummary?
	public let groupedHistory: AgentTranscriptGroupedHistory?
	public let defaultPresentation: AgentTranscriptBlockPresentation

	public init(
		id: String,
		kind: AgentTranscriptRenderBlockKind,
		turnID: UUID,
		spanID: UUID? = nil,
		retentionTier: AgentTranscriptRetentionTier,
		rows: [AgentChatItem],
		isArchived: Bool,
		primaryAnchor: AgentTranscriptAnchor? = nil,
		anchorActivityID: UUID? = nil,
		activityIDs: [UUID] = [],
		clusterSummary: AgentTranscriptClusterSummary? = nil,
		groupedHistory: AgentTranscriptGroupedHistory? = nil,
		defaultPresentation: AgentTranscriptBlockPresentation = .expanded
	) {
		self.id = id
		self.kind = kind
		self.turnID = turnID
		self.spanID = spanID
		self.retentionTier = retentionTier
		self.rows = rows
		self.isArchived = isArchived
		self.primaryAnchor = primaryAnchor
		self.anchorActivityID = anchorActivityID
		self.activityIDs = activityIDs
		self.clusterSummary = clusterSummary
		self.groupedHistory = groupedHistory
		self.defaultPresentation = defaultPresentation
	}
}

public struct AgentTranscriptProjection: Sendable, Equatable {
	public var workingBlocks: [AgentTranscriptRenderBlock]
	public var archivedBlocks: [AgentTranscriptRenderBlock]
	public var workingRows: [AgentChatItem]
	public var archivedRows: [AgentChatItem]
	public var rowAnchorIndex: [UUID: AgentTranscriptAnchor]
	public var anchorBlockIndex: [AgentTranscriptAnchor: String]
	public var workingUnitCount: Int

	public init(
		workingBlocks: [AgentTranscriptRenderBlock] = [],
		archivedBlocks: [AgentTranscriptRenderBlock] = [],
		workingRows: [AgentChatItem] = [],
		archivedRows: [AgentChatItem] = [],
		rowAnchorIndex: [UUID: AgentTranscriptAnchor] = [:],
		anchorBlockIndex: [AgentTranscriptAnchor: String] = [:],
		workingUnitCount: Int = 0
	) {
		self.workingBlocks = workingBlocks
		self.archivedBlocks = archivedBlocks
		self.workingRows = workingRows
		self.archivedRows = archivedRows
		self.rowAnchorIndex = rowAnchorIndex
		self.anchorBlockIndex = anchorBlockIndex
		self.workingUnitCount = workingUnitCount
	}

	public static let empty = AgentTranscriptProjection()
}

public struct AgentTranscriptTurnProjectionCache: Sendable, Equatable {
	public struct ValidationToken: Sendable, Equatable {
		public let turnID: UUID
		public let retentionTier: AgentTranscriptRetentionTier
		public let isCompleted: Bool
		public let responseSpanCount: Int
		public let activityCount: Int
		public let conclusionActivityID: UUID?
		public let frozenDetailedToolTailLimit: Int?
	
    public init(turnID: UUID, retentionTier: AgentTranscriptRetentionTier, isCompleted: Bool, responseSpanCount: Int, activityCount: Int, conclusionActivityID: UUID?, frozenDetailedToolTailLimit: Int?) {
        self.turnID = turnID
        self.retentionTier = retentionTier
        self.isCompleted = isCompleted
        self.responseSpanCount = responseSpanCount
        self.activityCount = activityCount
        self.conclusionActivityID = conclusionActivityID
        self.frozenDetailedToolTailLimit = frozenDetailedToolTailLimit
    }
}

	public let token: ValidationToken
	public let workingBlocks: [AgentTranscriptRenderBlock]
	public let archivedBlocks: [AgentTranscriptRenderBlock]
	public let workingRows: [AgentChatItem]
	public let archivedRows: [AgentChatItem]
	public let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
	public let anchorBlockIndex: [AgentTranscriptAnchor: String]

    public init(token: ValidationToken, workingBlocks: [AgentTranscriptRenderBlock], archivedBlocks: [AgentTranscriptRenderBlock], workingRows: [AgentChatItem], archivedRows: [AgentChatItem], rowAnchorIndex: [UUID: AgentTranscriptAnchor], anchorBlockIndex: [AgentTranscriptAnchor: String]) {
        self.token = token
        self.workingBlocks = workingBlocks
        self.archivedBlocks = archivedBlocks
        self.workingRows = workingRows
        self.archivedRows = archivedRows
        self.rowAnchorIndex = rowAnchorIndex
        self.anchorBlockIndex = anchorBlockIndex
    }
}

public struct AgentTranscriptProjectionBuildResult: Sendable, Equatable {
	public let projection: AgentTranscriptProjection
	public let updatedTurnCaches: [UUID: AgentTranscriptTurnProjectionCache]

    public init(projection: AgentTranscriptProjection, updatedTurnCaches: [UUID: AgentTranscriptTurnProjectionCache]) {
        self.projection = projection
        self.updatedTurnCaches = updatedTurnCaches
    }
}

public struct AgentTranscriptProjectionBuildMetrics: Sendable, Equatable {
	public let turnCount: Int
	public let reusedPrefixTurnCount: Int
	public let cacheHitCount: Int
	public let workingBlockCount: Int
	public let archivedBlockCount: Int
	public let workingRowCount: Int
	public let archivedRowCount: Int
	public let workingUnitCount: Int
	public let durationMS: Double

    public init(turnCount: Int, reusedPrefixTurnCount: Int, cacheHitCount: Int, workingBlockCount: Int, archivedBlockCount: Int, workingRowCount: Int, archivedRowCount: Int, workingUnitCount: Int, durationMS: Double) {
        self.turnCount = turnCount
        self.reusedPrefixTurnCount = reusedPrefixTurnCount
        self.cacheHitCount = cacheHitCount
        self.workingBlockCount = workingBlockCount
        self.archivedBlockCount = archivedBlockCount
        self.workingRowCount = workingRowCount
        self.archivedRowCount = archivedRowCount
        self.workingUnitCount = workingUnitCount
        self.durationMS = durationMS
    }
}

public struct AgentArchivedTranscriptProjection: Sendable, Equatable {
    public let blocks: [AgentTranscriptRenderBlock]
    public let rows: [AgentChatItem]
    public let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
    public let anchorBlockIndex: [AgentTranscriptAnchor: String]
    public let presentedRowCount: Int
    public let blockCount: Int
    public init(blocks: [AgentTranscriptRenderBlock], rows: [AgentChatItem],
                rowAnchorIndex: [UUID: AgentTranscriptAnchor], anchorBlockIndex: [AgentTranscriptAnchor: String],
                presentedRowCount: Int, blockCount: Int) {
        self.blocks = blocks; self.rows = rows; self.rowAnchorIndex = rowAnchorIndex
        self.anchorBlockIndex = anchorBlockIndex; self.presentedRowCount = max(0, presentedRowCount)
        self.blockCount = max(0, blockCount)
    }
}
