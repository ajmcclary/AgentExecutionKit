import Foundation
import ClaudeRuntimeKit

/// Extracts the primitive wire facts a lifecycle observation needs from a raw
/// Claude stream payload, then hands them to the single normalizer in
/// `ClaudeRuntimeCore`.
///
/// This is deliberately NOT a second normalizer: it makes no classification
/// decision of its own. It reads fields out of `[String: Any]` — a shape the
/// Foundation-only core has no business knowing about — and every judgment about
/// what those fields MEAN belongs to `ClaudeLifecycleNormalizer`. R12 ratchets
/// that separation.
public enum ClaudeLifecycleIngressExtractor {

	public static func lifecycleEvent(from payload: [String: Any]) -> ClaudeLifecycleEvent? {
		let payloadType = (payload["type"] as? String) ?? ""
		let subtype = payload["subtype"] as? String
		let sessionState = firstString(
			in: payload,
			keys: ["session_state", "sessionState", "state", "current_state", "currentState"]
		)
		// `uuid`/`id` matches the identity Slice 4a already uses for the billed-turn
		// aggregate, so the two normalized lanes name the same result the same way.
		let identity = ClaudeLifecycleIdentity(
			sessionID: firstString(in: payload, keys: ["session_id", "sessionId"]),
			messageID: firstString(in: payload, keys: ["uuid", "id"]),
			taskID: firstString(in: payload, keys: ["task_id", "taskId"])
		)
		return ClaudeLifecycleNormalizer.lifecycleEvent(
			payloadType: payloadType,
			subtype: subtype,
			sessionState: sessionState,
			identity: identity
		)
	}

	private static func firstString(in payload: [String: Any], keys: [String]) -> String? {
		for key in keys {
			if let value = payload[key] as? String {
				let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmed.isEmpty { return trimmed }
			}
		}
		return nil
	}
}
