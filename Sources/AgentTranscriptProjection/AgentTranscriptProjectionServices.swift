import Foundation
import AgentRuntimeKit

/// Caller-owned ports. A fresh tool processor is made per projection operation;
/// explicit caller caches may be captured by the host factory when desired.
public struct AgentTranscriptProjectionServices {
    public var makeToolProcessor: () -> (AgentChatItem) -> AgentTranscriptToolExecution?
    public var normalizedToolName: (String?) -> String?
    public var suppressActivity: (AgentTranscriptActivity) -> Bool
    public var buildToolGroups: ([String], [String:Int]) -> [ClusterToolGroup]
    public var sanitizeGroupedSummary: (AgentTranscriptGroupedHistorySummary) -> AgentTranscriptGroupedHistorySummary
    public var groupedDisplay: (AgentTranscriptGroupedHistorySummary) -> AgentTranscriptCollapsedSummaryDisplay?
    public var clusterDisplay: (AgentTranscriptClusterSummary, Int) -> AgentTranscriptCollapsedSummaryDisplay?
    public var sectionTitleAndIcon: (AgentTranscriptGroupedSectionKind, AgentTranscriptClusterSummary?) -> (title:String?, icon:String?)
    public var clock: () -> TimeInterval
    public var diagnosticsEnabled: () -> Bool
    public var log: (String) -> Void
    public var observeBuild: (AgentTranscriptProjectionBuildMetrics) -> Void
    public init(makeToolProcessor: @escaping () -> (AgentChatItem) -> AgentTranscriptToolExecution?,
                normalizedToolName: @escaping (String?) -> String?, suppressActivity: @escaping (AgentTranscriptActivity) -> Bool,
                buildToolGroups: @escaping ([String], [String:Int]) -> [ClusterToolGroup],
                sanitizeGroupedSummary: @escaping (AgentTranscriptGroupedHistorySummary) -> AgentTranscriptGroupedHistorySummary,
                groupedDisplay: @escaping (AgentTranscriptGroupedHistorySummary) -> AgentTranscriptCollapsedSummaryDisplay?,
                clusterDisplay: @escaping (AgentTranscriptClusterSummary, Int) -> AgentTranscriptCollapsedSummaryDisplay?,
                sectionTitleAndIcon: @escaping (AgentTranscriptGroupedSectionKind, AgentTranscriptClusterSummary?) -> (title:String?,icon:String?),
                clock: @escaping () -> TimeInterval, diagnosticsEnabled: @escaping () -> Bool,
                log: @escaping (String) -> Void, observeBuild: @escaping (AgentTranscriptProjectionBuildMetrics) -> Void) {
        self.makeToolProcessor = makeToolProcessor; self.normalizedToolName = normalizedToolName
        self.suppressActivity = suppressActivity
        self.buildToolGroups = buildToolGroups; self.sanitizeGroupedSummary = sanitizeGroupedSummary
        self.groupedDisplay = groupedDisplay; self.clusterDisplay = clusterDisplay
        self.sectionTitleAndIcon = sectionTitleAndIcon; self.clock = clock
        self.diagnosticsEnabled = diagnosticsEnabled; self.log = log; self.observeBuild = observeBuild
    }
}
