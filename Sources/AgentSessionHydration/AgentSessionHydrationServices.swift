import Foundation
import AgentRuntimeKit
import AgentSessionContracts

/// Sendable host inputs; the service inherits the caller's actor isolation.
/// Loader storage scope, provider selection, presentation and index schema are host-owned.
public struct AgentSessionHydrationServices<Selection: Sendable, Presentation: Sendable, Index: Sendable>: Sendable {
    public var load: @Sendable (UUID) async throws -> AgentSession?
    public var select: @Sendable (AgentSession) -> Selection
    public var persistedWorkingItems: @Sendable (AgentSession) -> [AgentChatItem]
    public var containsExcludedRows: @Sendable (AgentTranscript, Bool) -> Bool
    public var rebuild: @Sendable (AgentTranscript, [AgentChatItem], AgentSessionRunState, Bool) -> AgentTranscript
    public var build: @Sendable ([AgentChatItem], AgentSessionRunState, Int, Bool) -> AgentTranscript
    public var normalizeFrozenLimits: @Sendable (AgentTranscript) -> AgentTranscript
    public var workingItems: @Sendable (AgentTranscript) -> [AgentChatItem]
    public var protectedTurnID: @Sendable (AgentTranscript) -> UUID?
    public var present: @Sendable (AgentTranscript, [AgentChatItem], Selection, UUID?) -> Presentation
    public var transcriptRecency: @Sendable (AgentTranscript) -> Date?
    public var itemRecency: @Sendable ([AgentChatItem]) -> Date?
    public var visibleCount: @Sendable (Presentation) -> Int
    public var index: @Sendable (AgentSession, Date?, Int) -> Index
    public var clockMS: @Sendable () -> Double?
    public var observe: @Sendable (AgentSessionHydrationObservation) -> Void

    public init(load: @escaping @Sendable (UUID) async throws -> AgentSession?,
                select: @escaping @Sendable (AgentSession) -> Selection,
                persistedWorkingItems: @escaping @Sendable (AgentSession) -> [AgentChatItem],
                containsExcludedRows: @escaping @Sendable (AgentTranscript, Bool) -> Bool,
                rebuild: @escaping @Sendable (AgentTranscript, [AgentChatItem], AgentSessionRunState, Bool) -> AgentTranscript,
                build: @escaping @Sendable ([AgentChatItem], AgentSessionRunState, Int, Bool) -> AgentTranscript,
                normalizeFrozenLimits: @escaping @Sendable (AgentTranscript) -> AgentTranscript,
                workingItems: @escaping @Sendable (AgentTranscript) -> [AgentChatItem],
                protectedTurnID: @escaping @Sendable (AgentTranscript) -> UUID?,
                present: @escaping @Sendable (AgentTranscript, [AgentChatItem], Selection, UUID?) -> Presentation,
                transcriptRecency: @escaping @Sendable (AgentTranscript) -> Date?,
                itemRecency: @escaping @Sendable ([AgentChatItem]) -> Date?,
                visibleCount: @escaping @Sendable (Presentation) -> Int,
                index: @escaping @Sendable (AgentSession, Date?, Int) -> Index,
                clockMS: @escaping @Sendable () -> Double? = { nil },
                observe: @escaping @Sendable (AgentSessionHydrationObservation) -> Void = { _ in }) {
        self.load = load; self.select = select; self.persistedWorkingItems = persistedWorkingItems
        self.containsExcludedRows = containsExcludedRows; self.rebuild = rebuild; self.build = build
        self.normalizeFrozenLimits = normalizeFrozenLimits; self.workingItems = workingItems; self.protectedTurnID = protectedTurnID; self.present = present
        self.transcriptRecency = transcriptRecency; self.itemRecency = itemRecency; self.visibleCount = visibleCount
        self.index = index; self.clockMS = clockMS; self.observe = observe
    }
}

public enum AgentSessionHydrationOutcome: String, Sendable { case missingSession, payload, cancelled, error }
public struct AgentSessionHydrationObservation: Sendable {
    public let outcome: AgentSessionHydrationOutcome
    public let loadDurationMS: Double?
    public let transcriptDurationMS: Double?
    public let presentationDurationMS: Double?
    public let totalDurationMS: Double?
    public let canonicalLiveItems: Int?
    public let turns: Int?
    public let needsReloadMigrationSave: Bool?
    public let frozenTailLimitNormalizationNeeded: Bool?
    public let errorDescription: String?
}
public struct AgentSessionHydrationResult<Selection: Sendable, Presentation: Sendable, Index: Sendable>: Sendable {
    public let sessionID: UUID
    public let persistedSession: AgentSession
    public let canonicalLiveItems: [AgentChatItem]
    public let transcript: AgentTranscript
    public let builtPresentation: Presentation
    public let normalizedRunState: AgentSessionRunState
    public let normalizedSelection: Selection
    public let lastUserMessageAt: Date?
    public let restoredIndexEntry: Index
    public let needsReloadMigrationSave: Bool
}
