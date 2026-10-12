import Foundation
import AgentRuntimeKit

public struct AgentTranscriptToolProcessor {
    let execution: (AgentChatItem) -> AgentTranscriptToolExecution?
    let normalizedName: (String?) -> String?
    let sealsBoundary: (AgentChatItem, AgentTranscriptToolExecution?) -> Bool
    public init(execution: @escaping (AgentChatItem) -> AgentTranscriptToolExecution?,
                normalizedName: @escaping (String?) -> String?,
                sealsBoundary: @escaping (AgentChatItem, AgentTranscriptToolExecution?) -> Bool) {
        self.execution = execution; self.normalizedName = normalizedName; self.sealsBoundary = sealsBoundary
    }
}

/// Hosts supply concrete tool meaning, visual allocation and summary presentation.
/// The execution service owns ordering, grouping, pairing, lifecycle and conclusion selection.
public struct AgentTranscriptAssemblyServices {
    let makeToolProcessor: () -> AgentTranscriptToolProcessor
    let summarizeTurn: (AgentTranscriptTurn) -> AgentTranscriptTurnSummary?
    let summarizeSpan: (AgentTranscriptProviderResponseSpan, AgentTranscriptTurn) -> AgentTranscriptGroupedHistorySummary?
    let frozenTailLimit: (AgentTranscriptTurn, [AgentTranscriptTurn]) -> Int?
    public init(makeToolProcessor: @escaping () -> AgentTranscriptToolProcessor,
                summarizeTurn: @escaping (AgentTranscriptTurn) -> AgentTranscriptTurnSummary?,
                summarizeSpan: @escaping (AgentTranscriptProviderResponseSpan, AgentTranscriptTurn) -> AgentTranscriptGroupedHistorySummary?,
                frozenTailLimit: @escaping (AgentTranscriptTurn, [AgentTranscriptTurn]) -> Int?) {
        self.makeToolProcessor = makeToolProcessor; self.summarizeTurn = summarizeTurn
        self.summarizeSpan = summarizeSpan; self.frozenTailLimit = frozenTailLimit
    }
}
