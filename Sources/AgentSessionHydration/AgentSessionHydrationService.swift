import Foundation
import AgentRuntimeKit
import AgentSessionContracts
import AgentTranscriptPersistence

public struct AgentSessionHydrationService<Selection: Sendable, Presentation: Sendable, Index: Sendable>: Sendable {
    private let services: AgentSessionHydrationServices<Selection, Presentation, Index>
    public init(services: AgentSessionHydrationServices<Selection, Presentation, Index>) { self.services = services }

    /// Inherits the caller's actor without unchecked transfers or new scheduling.
    public func prepare(sessionID: UUID, hasPendingQuestionUI: Bool,
                        isolation: isolated (any Actor)? = #isolation) async throws -> AgentSessionHydrationResult<Selection, Presentation, Index>? {
        #if DEBUG
        let start = services.clockMS()
        var loadDuration: Double?, transcriptDuration: Double?, presentationDuration: Double?
        func elapsed(_ start: Double?) -> Double? {
            guard let start, let end = services.clockMS() else { return nil }
            return end - start
        }
        func observe(_ outcome: AgentSessionHydrationOutcome, items: Int? = nil, turns: Int? = nil,
                     migration: Bool? = nil, frozen: Bool? = nil, error: Error? = nil) {
            services.observe(.init(outcome: outcome, loadDurationMS: loadDuration,
                transcriptDurationMS: transcriptDuration, presentationDurationMS: presentationDuration,
                totalDurationMS: elapsed(start), canonicalLiveItems: items, turns: turns,
                needsReloadMigrationSave: migration, frozenTailLimitNormalizationNeeded: frozen,
                errorDescription: error.map { String(describing: $0) }))
        }
        #endif
        do {
            try Task.checkCancellation()
            #if DEBUG
            let loadStart = services.clockMS()
            #endif
            guard let session = try await services.load(sessionID) else {
                #if DEBUG
                loadDuration = elapsed(loadStart); observe(.missingSession)
                #endif
                return nil
            }
            #if DEBUG
            loadDuration = elapsed(loadStart)
            let transcriptStart = services.clockMS()
            #endif
            let runState = AgentTranscriptColdRestore.normalizedRunState(session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:)))
            let selection = services.select(session)
            let persistedItems = services.persistedWorkingItems(session)
            let loaded: AgentTranscript
            if let transcript = session.transcript {
                if services.containsExcludedRows(transcript, hasPendingQuestionUI) {
                    loaded = services.rebuild(transcript, persistedItems, runState, hasPendingQuestionUI)
                } else { loaded = transcript }
            } else {
                loaded = services.build(persistedItems, runState, (persistedItems.map(\.sequenceIndex).max() ?? -1) + 1, hasPendingQuestionUI)
            }
            let transcript = services.normalizeFrozenLimits(loaded)
            let frozenChanged = transcript != loaded
            let items = services.workingItems(transcript)
            let protection = services.protectedTurnID(transcript)
            #if DEBUG
            transcriptDuration = elapsed(transcriptStart)
            #endif
            try Task.checkCancellation()
            #if DEBUG
            let presentationStart = services.clockMS()
            #endif
            let presentation = services.present(transcript, items, selection, protection)
            #if DEBUG
            presentationDuration = elapsed(presentationStart)
            #endif
            try Task.checkCancellation()
            let recency = session.lastUserMessageAt ?? services.transcriptRecency(transcript) ?? services.itemRecency(items)
            let entry = services.index(session, recency, transcript.turns.isEmpty ? items.count : services.visibleCount(presentation))
            let migration = session.transcript != transcript || session.itemCount == nil || session.lastUserMessageAt == nil || frozenChanged
            #if DEBUG
            observe(.payload, items: items.count, turns: transcript.turns.count, migration: migration, frozen: frozenChanged)
            #endif
            return .init(sessionID: sessionID, persistedSession: session, canonicalLiveItems: items,
                transcript: transcript, builtPresentation: presentation, normalizedRunState: runState,
                normalizedSelection: selection, lastUserMessageAt: recency, restoredIndexEntry: entry,
                needsReloadMigrationSave: migration)
        } catch {
            #if DEBUG
            observe((error is CancellationError || Task.isCancelled) ? .cancelled : .error, error: error)
            #endif
            throw error
        }
    }
}
