import Foundation
import AgentRuntimeKit

public struct AgentTranscriptRowImportPolicy {
    private let isHiddenTool: (String?) -> Bool
    private let isQuestionTool: (String?) -> Bool
    public init(isHiddenTool: @escaping (String?) -> Bool, isQuestionTool: @escaping (String?) -> Bool) {
        self.isHiddenTool = isHiddenTool; self.isQuestionTool = isQuestionTool
    }
    public func shouldInclude(_ item: AgentChatItem, policy: AgentTranscriptImportPolicy = .canonical) -> Bool {
        if policy.hideAlwaysHiddenTools, (item.kind == .toolCall || item.kind == .toolResult), isHiddenTool(item.toolName) { return false }
        if policy.hidePendingQuestionToolCall, item.kind == .toolCall, isQuestionTool(item.toolName) { return false }
        return true
    }
    public func filtered(_ items: [AgentChatItem], policy: AgentTranscriptImportPolicy = .canonical) -> [AgentChatItem] {
        items.filter { shouldInclude($0, policy: policy) }
    }
    public func containsExcluded(_ items: [AgentChatItem], policy: AgentTranscriptImportPolicy = .canonical) -> Bool {
        items.contains { !shouldInclude($0, policy: policy) }
    }
    public func containsRowsExcluded(in transcript: AgentTranscript, policy: AgentTranscriptImportPolicy = .canonical) -> Bool {
        containsExcluded(AgentTranscriptTextExtraction.flattenFullTranscript(transcript), policy: policy)
    }
}
