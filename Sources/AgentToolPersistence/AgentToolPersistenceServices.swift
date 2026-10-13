import Foundation
import AgentRuntimeKit

/// Caller-owned ports. Summaries and wire schema remain host policy. The fallback
/// JSON renderer must produce the host's bounded, storage-safe minimal envelope.
public struct AgentToolPersistenceServices {
    public var execution: (AgentChatItem) -> AgentTranscriptToolExecution?
    public var visibleName: (String?) -> String?
    public var pathSignal: (String?) -> String?
    public var storeExecution: (AgentTranscriptToolExecution, UUID) -> Void
    public var runtimeSummary: (AgentChatItem, AgentTranscriptToolExecution?) -> AgentSanitizedToolResult?
    public var persistedSummary: (AgentChatItem, AgentTranscriptToolExecution, String) -> AgentPersistedToolResultSummary?
    public var storagePresentation: (AgentChatItem, AgentTranscriptToolExecution, String?) -> AgentToolStoragePresentation
    public var callSummary: (String?, String?, AgentTranscriptToolStatus) -> String
    public var fallbackJSON: (AgentTranscriptToolStatus, String?, String?, Int?, String?) -> String

    public init(execution: @escaping (AgentChatItem) -> AgentTranscriptToolExecution?,
                visibleName: @escaping (String?) -> String?, pathSignal: @escaping (String?) -> String?,
                storeExecution: @escaping (AgentTranscriptToolExecution, UUID) -> Void,
                runtimeSummary: @escaping (AgentChatItem, AgentTranscriptToolExecution?) -> AgentSanitizedToolResult?,
                persistedSummary: @escaping (AgentChatItem, AgentTranscriptToolExecution, String) -> AgentPersistedToolResultSummary?,
                storagePresentation: @escaping (AgentChatItem, AgentTranscriptToolExecution, String?) -> AgentToolStoragePresentation,
                callSummary: @escaping (String?, String?, AgentTranscriptToolStatus) -> String,
                fallbackJSON: @escaping (AgentTranscriptToolStatus, String?, String?, Int?, String?) -> String) {
        self.execution = execution; self.visibleName = visibleName; self.pathSignal = pathSignal
        self.storeExecution = storeExecution; self.runtimeSummary = runtimeSummary
        self.persistedSummary = persistedSummary; self.storagePresentation = storagePresentation
        self.callSummary = callSummary; self.fallbackJSON = fallbackJSON
    }
}
