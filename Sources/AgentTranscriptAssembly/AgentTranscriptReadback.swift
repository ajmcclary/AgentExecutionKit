import Foundation
import AgentRuntimeKit

public struct AgentTranscriptReadback {
    private let renderRows: (AgentTranscriptTurn, Bool) -> [AgentChatItem]
    private let suppressRow: (AgentChatItem) -> Bool
    private let visibleToolName: (String?) -> String?
    public init(renderRows: @escaping (AgentTranscriptTurn, Bool) -> [AgentChatItem],
                suppressRow: @escaping (AgentChatItem) -> Bool,
                visibleToolName: @escaping (String?) -> String?) {
        self.renderRows = renderRows; self.suppressRow = suppressRow; self.visibleToolName = visibleToolName
    }
	public func conversationHistory(
		from transcript: AgentTranscript,
		renderUserMessage: ((AgentTranscriptRequestAnchor) -> String)? = nil
	) -> String {
		var lines: [String] = []
		for turn in transcript.turns {
			if let request = turn.request {
				let rendered = renderUserMessage?(request) ?? request.text
				lines.append("<user>\(rendered)</user>")
			}
			for activity in renderRows(turn, true) {
				if suppressRow(activity) {
					continue
				}
				switch activity.kind {
				case .assistant, .assistantInline:
					if AgentDisplayableText.hasDisplayableBody(activity.text) {
						let trimmed = activity.text.trimmingCharacters(in: .whitespacesAndNewlines)
						lines.append("<assistant>\(trimmed)</assistant>")
					}
				case .toolCall:
					if let toolName = visibleToolName(activity.toolName) {
						let args = activity.toolArgsJSON ?? ""
						if args.isEmpty {
							lines.append("<tool_call name=\"\(toolName)\"/>")
						} else {
							lines.append("<tool_call name=\"\(toolName)\">\(args)</tool_call>")
						}
					}
				case .toolResult:
					if let toolName = visibleToolName(activity.toolName) {
						lines.append("<tool_result name=\"\(toolName)\"/>")
					}
				case .system:
					lines.append("<system>\(activity.text)</system>")
				case .error:
					lines.append("<error>\(activity.text)</error>")
				case .user, .thinking:
					break
				}
			}
		}
		return lines.joined(separator: "\n")
	}

	public static func workingSourceItems(from transcript: AgentTranscript) -> [AgentChatItem] {
		let rows = transcript.turns
			.filter { $0.retentionTier == .full }
			.flatMap { turn in
				var rows: [AgentChatItem] = []
				if let request = turn.request {
					rows.append(request.toItem())
				}
				rows.append(contentsOf: turn.allActivities.map { $0.toItem() })
				return rows
			}
			.sorted { lhs, rhs in
				if lhs.sequenceIndex == rhs.sequenceIndex {
					return lhs.timestamp < rhs.timestamp
				}
				return lhs.sequenceIndex < rhs.sequenceIndex
			}
		return rows
	}

}
