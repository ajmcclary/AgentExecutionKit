import Foundation
import AgentClaudeProtocol
import AgentClaudeEvents

/// Wire verdict only; generation-targeted interrupts belong to the lifecycle owner.
public enum ClaudeNativeTurnStatusClassifier {
	public static func classify(
		_ payload: ClaudeProtocolJSONObject,
		stopReasonHint: String? = nil
	) throws -> ClaudeNativeTurnStatus {
		let payload = try payload.dictionary()
		let subtype = ((payload["subtype"] as? String) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		let stopReason = ((payload["stop_reason"] as? String) ?? "")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()

		if Self.isCancelledTurnSignal(subtype)
			|| Self.isCancelledTurnSignal(stopReason)
			|| Self.isCancelledTurnSignal(stopReasonHint) {
			return .cancelled
		}
		if let streamEvent = payload["event"] as? [String: Any],
			let delta = streamEvent["delta"] as? [String: Any],
			let nestedStopReason = (delta["stop_reason"] as? String),
			Self.isCancelledTurnSignal(nestedStopReason) {
			return .cancelled
		}

		let resultErrors = Self.extractResultErrors(from: payload)
		if resultErrors.contains(where: { Self.isCancelledTurnSignal($0) }) {
			return .cancelled
		}

		if (payload["is_error"] as? Bool) == true
			|| subtype.contains("error")
			|| !resultErrors.isEmpty {
			return .failed
		}
		return .completed
	}

	private static func extractResultErrors(from payload: [String: Any]) -> [String] {
		guard let errors = payload["errors"] as? [Any] else { return [] }
		return errors.compactMap { entry in
			switch entry {
			case let text as String:
				let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
				return trimmed.isEmpty ? nil : trimmed
			case let object as [String: Any]:
				let message = (object["message"] as? String) ?? (object["error"] as? String)
				let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
				return trimmed.isEmpty ? nil : trimmed
			default:
				return nil
			}
		}
	}

	private static func isCancelledTurnSignal(_ value: String?) -> Bool {
		guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			!value.isEmpty else {
			return false
		}
		return value.contains("interrupt")
			|| value.contains("cancel")
			|| value.contains("aborted")
			|| value.contains("request was aborted")
	}

}
