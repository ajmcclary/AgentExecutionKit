import Foundation
import AgentRuntimeKit

public struct AgentTranscriptRecencyPolicy {
	private let isQuestionTool: (String?) -> Bool
	public init(isQuestionTool: @escaping (String?) -> Bool) { self.isQuestionTool = isQuestionTool }
	public func lastUserInteractionDate(in items: [AgentChatItem]) -> Date? {
		let userInteraction = items.last(where: isUserInteractionItem(_:))
		return userInteraction?.timestamp
	}

	public func lastUserInteractionDate(in transcript: AgentTranscript) -> Date? {
		for turn in transcript.turns.reversed() {
			if let interactionDate = lastUserInteractionDate(in: turn) {
				return interactionDate
			}
		}
		return nil
	}

	public func isUserInteractionItem(_ item: AgentChatItem) -> Bool {
		if item.kind == .user {
			return true
		}
		guard item.kind == .toolResult,
			isQuestionTool(item.toolName),
			let result = item.toolResultJSON,
			let data = result.data(using: .utf8),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return false
		}
		return json["response"] != nil
			|| json["skipped"] as? Bool == true
			|| json["timed_out"] as? Bool == true
	}

	private func lastUserInteractionDate(in turn: AgentTranscriptTurn) -> Date? {
		var latest = turn.summary?.lastUserInteractionAt
		if let requestTimestamp = turn.request?.timestamp {
			latest = max(latest ?? requestTimestamp, requestTimestamp)
		}
		for activity in turn.allActivities {
			guard isUserInteractionItem(activity.toItem()) else { continue }
			let timestamp = activity.timestamp
			latest = max(latest ?? timestamp, timestamp)
		}
		return latest
	}

}
