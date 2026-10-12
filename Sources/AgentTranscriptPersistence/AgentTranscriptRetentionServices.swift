import Foundation
import AgentRuntimeKit

/// Caller-actor-owned collaborators. Classification, visual sizing and summary
/// presentation belong to the host; this service owns retention decisions/mutation.
public struct AgentTranscriptRetentionServices {
    let workingUnits: (AgentTranscript) -> Int
    let summaryWorkingUnits: (AgentTranscriptTurn) -> Int
    let suppressActivity: (AgentTranscriptActivity) -> Bool
    let summarizeTurn: (AgentTranscriptTurn) -> AgentTranscriptTurnSummary?
    let summarizeSpan: (AgentTranscriptProviderResponseSpan, AgentTranscriptTurn) -> AgentTranscriptGroupedHistorySummary?
    let compactConclusion: (String?) -> String?
    let diagnosticsEnabled: () -> Bool
    let clock: () -> TimeInterval
    let observeCompaction: (AgentTranscriptCompactionMetrics) -> Void
    let observeProtectedTail: (AgentTranscriptProtectedTailScanMetrics) -> Void

    public init(workingUnits: @escaping (AgentTranscript) -> Int,
                summaryWorkingUnits: @escaping (AgentTranscriptTurn) -> Int,
                suppressActivity: @escaping (AgentTranscriptActivity) -> Bool,
                summarizeTurn: @escaping (AgentTranscriptTurn) -> AgentTranscriptTurnSummary?,
                summarizeSpan: @escaping (AgentTranscriptProviderResponseSpan, AgentTranscriptTurn) -> AgentTranscriptGroupedHistorySummary?,
                compactConclusion: @escaping (String?) -> String?,
                clock: @escaping () -> TimeInterval,
                diagnosticsEnabled: @escaping () -> Bool = { false },
                observeCompaction: @escaping (AgentTranscriptCompactionMetrics) -> Void = { _ in },
                observeProtectedTail: @escaping (AgentTranscriptProtectedTailScanMetrics) -> Void = { _ in }) {
        self.workingUnits = workingUnits; self.summaryWorkingUnits = summaryWorkingUnits
        self.suppressActivity = suppressActivity; self.summarizeTurn = summarizeTurn
        self.summarizeSpan = summarizeSpan; self.compactConclusion = compactConclusion
        self.clock = clock; self.diagnosticsEnabled = diagnosticsEnabled
        self.observeCompaction = observeCompaction; self.observeProtectedTail = observeProtectedTail
    }
}
