import Foundation
import AgentRuntimeKit
import AgentTranscriptPersistence

func fixtureID(_ number: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d",number))! }
func fixtureSummary(_ turn: AgentTranscriptTurn, toolCount: Int = 0) -> AgentTranscriptTurnSummary {
    .init(middleSummaryItemID: turn.id, requestText: "request", conclusionText: "conclusion", compactConclusionText: nil,
          middleSummaryText: "middle", toolCount: toolCount, notableToolNames: [], keyPaths: [], compactedActivityCount: turn.allActivities.count, hadWarning: false, hadError: false)
}
func fixtureGroupedSummary(running: Bool = false, toolCount: Int = 1) -> AgentTranscriptGroupedHistorySummary {
    let display = AgentTranscriptCollapsedSummaryDisplay(title: "tools", count: toolCount, detailText: "detail", narrationText: "narration", toolGroupText: "group", status: running ? .running : .neutral)
    return .init(hiddenToolCardCount: toolCount, hiddenAssistantCount: 2, hiddenProgressCount: 3, hiddenNoteCount: 4,
                 toolSummary: .init(toolCount: toolCount, toolNames: ["read"], toolNameCounts: ["read":toolCount], keyPaths: ["file"], containsRunningWork: running, containsFailure: false, containsWarning: true, shortNarration: "narration", collapsedDisplay: display), collapsedDisplay: display)
}
func fixtureActivity(_ index: Int, kind: AgentChatItemKind = .assistant, status: AgentTranscriptToolStatus? = nil, executionID: String? = nil, text: String = "body") -> AgentTranscriptActivity {
    .init(id: fixtureID(index+1000), timestamp: Date(timeIntervalSince1970: Double(index)), sequenceIndex: index,
          role: status == nil ? .assistant : .toolExecution, itemKind: kind, text: text,
          toolExecution: status.map { .init(stableExecutionID: executionID ?? "exec-\(index)", toolName: "read", invocationID: fixtureID(index+2000), argsJSON: "{\"path\":\"file\"}", resultJSON: text, toolIsError: false, status: $0) })
}
func fixtureTurn(_ index: Int, tier: AgentTranscriptRetentionTier = .full, tools: Bool = false, completed: Bool = true) -> AgentTranscriptTurn {
    let date = Date(timeIntervalSince1970: Double(index*10))
    let tool = fixtureActivity(index*10+1, kind: tools ? .toolResult : .assistant, status: tools ? .success : nil)
    let conclusion = fixtureActivity(index*10+2)
    let request = AgentTranscriptRequestAnchor(from: AgentChatItem(timestamp: date, kind: .user, text: "request", sequenceIndex: index*10))
    return .init(id: fixtureID(index+1), request: request,
                 responseSpans: [.init(id: fixtureID(index+3000), lifecycle: completed ? .completed : .open, startedAt: date, activities: [tool,conclusion])],
                 conclusionActivityID: conclusion.id, retentionTier: tier, terminalState: completed ? .completed : .running,
                 startedAt: date, completedAt: completed ? date : nil)
}
func fixtureWorkingUnits(_ transcript: AgentTranscript) -> Int {
    transcript.turns.reduce(0) { total,turn in
        switch turn.retentionTier { case .full: total+5; case .condensed: total+2; case .summary: total+1; case .archived: total }
    }
}
func fixtureRetentionService(suppress: @escaping (AgentTranscriptActivity) -> Bool = { _ in false }, diagnostics: Bool = false,
                             observeCompaction: @escaping (AgentTranscriptCompactionMetrics)->Void = { _ in },
                             observeTail: @escaping (AgentTranscriptProtectedTailScanMetrics)->Void = { _ in }) -> AgentTranscriptRetentionService {
    .init(services: .init(workingUnits: fixtureWorkingUnits, summaryWorkingUnits: { _ in 1 }, suppressActivity: suppress,
                        summarizeTurn: { fixtureSummary($0) }, summarizeSpan: { _,_ in fixtureGroupedSummary() }, compactConclusion: { $0.map { "compact:"+$0 } },
                        clock: { 10 }, diagnosticsEnabled: { diagnostics }, observeCompaction: observeCompaction, observeProtectedTail: observeTail))
}
