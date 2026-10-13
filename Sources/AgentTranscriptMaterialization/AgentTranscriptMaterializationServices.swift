import Foundation
import AgentRuntimeKit
import AgentToolPersistence

/// Explicit host policy and presentation ports, invoked synchronously under the
/// caller's isolation. Sanitizers/refreshers must return independent value snapshots.
public struct AgentTranscriptMaterializationServices<Projection> {
    public var compact: (AgentTranscript, UUID?) -> AgentTranscript
    public var truncateTranscript: (AgentTranscript) -> AgentTranscript
    public var truncateExportSlice: ([AgentTranscriptTurn]) -> [AgentTranscriptTurn]
    public var sanitizeRuntime: (AgentTranscript, Set<UUID>) -> AgentSanitizedTranscriptMetrics
    public var sanitizeStorage: (AgentTranscript) -> AgentSanitizedTranscriptMetrics
    public var refreshCaches: (AgentTranscript) -> AgentTranscript
    public var project: (AgentTranscript) -> Projection
    public var visibleToolResultRowIDs: (Projection) -> Set<UUID>
    public var retainedFullDetailBytes: (AgentTranscript) -> Int

    public init(compact: @escaping (AgentTranscript, UUID?) -> AgentTranscript,
                truncateTranscript: @escaping (AgentTranscript) -> AgentTranscript,
                truncateExportSlice: @escaping ([AgentTranscriptTurn]) -> [AgentTranscriptTurn],
                sanitizeRuntime: @escaping (AgentTranscript, Set<UUID>) -> AgentSanitizedTranscriptMetrics,
                sanitizeStorage: @escaping (AgentTranscript) -> AgentSanitizedTranscriptMetrics,
                refreshCaches: @escaping (AgentTranscript) -> AgentTranscript,
                project: @escaping (AgentTranscript) -> Projection,
                visibleToolResultRowIDs: @escaping (Projection) -> Set<UUID>,
                retainedFullDetailBytes: @escaping (AgentTranscript) -> Int) {
        self.compact = compact; self.truncateTranscript = truncateTranscript
        self.truncateExportSlice = truncateExportSlice; self.sanitizeRuntime = sanitizeRuntime
        self.sanitizeStorage = sanitizeStorage; self.refreshCaches = refreshCaches
        self.project = project; self.visibleToolResultRowIDs = visibleToolResultRowIDs
        self.retainedFullDetailBytes = retainedFullDetailBytes
    }
}

public struct AgentTranscriptMaterializationResult<Projection> {
    public let transcript: AgentTranscript
    public let projection: Projection
    public let visibleToolResultRowIDs: Set<UUID>
    public let sanitizedActivityCount: Int
    public let retainedFullDetailBytes: Int
    public init(transcript: AgentTranscript, projection: Projection, visibleToolResultRowIDs: Set<UUID>,
                sanitizedActivityCount: Int, retainedFullDetailBytes: Int) {
        self.transcript = transcript; self.projection = projection
        self.visibleToolResultRowIDs = visibleToolResultRowIDs
        self.sanitizedActivityCount = sanitizedActivityCount; self.retainedFullDetailBytes = retainedFullDetailBytes
    }
}

extension AgentTranscriptMaterializationResult: Sendable where Projection: Sendable {}
