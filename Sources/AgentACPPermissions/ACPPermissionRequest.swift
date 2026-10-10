import Foundation
import AgentACPRPC

public enum ACPPermissionBounds {
	public static let toolCallIDBytes = 512
	public static let titleBytes = 4_096
	public static let kindBytes = 128
	public static let optionIDBytes = 256
	public static let optionKindBytes = 128
	public static let optionCount = 32
	public static let rawInputJSONBytes = 64 * 1024
	/// Total bytes of the serialized approval-details "Options" projection.
	public static let optionsDetailBytes = 16 * 1024
}

public struct ACPPermissionRequest: Sendable {
	public let rpcID: ACPRequestID
	public let storageKey: String
	public let sessionID: String
	public let toolCallID: String
	public let toolTitle: String?
	public let toolKind: String?
	public let rawInputJSON: String?
	public let options: [ACPPermissionOption]
	public let sessionScopedOptionID: String?
}

public enum ACPPermissionRefusal: Error, Sendable {
	case foreignSession
	case malformedToolCall
	case malformedOptions
	case retiredScope

	public var message: String {
		switch self {
		case .retiredScope: return "session/request_permission is not owned by an active turn"
		case .foreignSession:
			return "session/request_permission does not name the active session"
		case .malformedToolCall:
			return "session/request_permission requires a bounded toolCall with a non-empty toolCallId"
		case .malformedOptions:
			return "session/request_permission requires a bounded, non-empty set of unique options"
		}
	}
}

public enum ACPPermissionValidation {
	public static func validate(
		id: ACPRequestID,
		params: [String: Any],
		boundSessionID: String?, policy: ACPPermissionPolicy
	) -> Result<ACPPermissionRequest, ACPPermissionRefusal> {
		guard let sessionID = boundSessionID, let candidate = params["sessionId"] as? String,
			candidate.utf8.elementsEqual(sessionID.utf8) else {
			return .failure(.foreignSession)
		}
		guard let toolCall = params["toolCall"] as? [String: Any],
			let rawToolCallID = toolCall["toolCallId"] as? String else {
			return .failure(.malformedToolCall)
		}
		let toolCallID = rawToolCallID.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !toolCallID.isEmpty, toolCallID.utf8.count <= ACPPermissionBounds.toolCallIDBytes else {
			return .failure(.malformedToolCall)
		}

		// Present-but-wrong-typed is malformed; absent and explicit null are simply
		// absent. Bounds are UTF-8 BYTES, checked BEFORE trimming, so a grapheme carrying
		// millions of combining-mark bytes cannot pass a "character" limit.
		func boundedString(_ raw: Any?, limitBytes: Int) -> Result<String?, ACPPermissionRefusal> {
			guard let raw, !(raw is NSNull) else { return .success(nil) }
			guard let text = raw as? String, text.utf8.count <= limitBytes else {
				return .failure(.malformedToolCall)
			}
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			return .success(trimmed.isEmpty ? nil : trimmed)
		}

		let toolTitle: String?
		switch boundedString(toolCall["title"], limitBytes: ACPPermissionBounds.titleBytes) {
		case .failure(let refusal): return .failure(refusal)
		case .success(let value): toolTitle = value
		}
		let toolKind: String?
		switch boundedString(toolCall["kind"], limitBytes: ACPPermissionBounds.kindBytes) {
		case .failure(let refusal): return .failure(refusal)
		case .success(let value): toolKind = value?.lowercased()
		}

		guard let optionDictionaries = params["options"] as? [[String: Any]],
			!optionDictionaries.isEmpty,
			optionDictionaries.count <= ACPPermissionBounds.optionCount else {
			return .failure(.malformedOptions)
		}
		var seenOptionIDs = Set<String>()
		var options: [ACPPermissionOption] = []
		for optionDictionary in optionDictionaries {
			guard let rawOptionID = optionDictionary["optionId"] as? String,
				let rawOptionKind = optionDictionary["kind"] as? String else {
				return .failure(.malformedOptions)
			}
			let optionID = rawOptionID.trimmingCharacters(in: .whitespacesAndNewlines)
			let optionKind = rawOptionKind.trimmingCharacters(in: .whitespacesAndNewlines)
			// UTF-8 byte bounds, and the raw dictionary's arbitrary EXTRA keys are dropped
			// here — only these two typed fields survive validation, so no unbounded
			// nested payload can ride an option to the approval UI.
			guard !optionID.isEmpty, optionID.utf8.count <= ACPPermissionBounds.optionIDBytes,
				!optionKind.isEmpty, optionKind.utf8.count <= ACPPermissionBounds.optionKindBytes else {
				return .failure(.malformedOptions)
			}
			// Two options that select identically are ambiguous, not redundant.
			guard seenOptionIDs.insert(optionID.lowercased()).inserted else {
				return .failure(.malformedOptions)
			}
			// An unknown future kind is KEPT rather than dropped: it stays visible to the
			// user and can still be chosen by an explicit option-id preference. What it
			// never does is make a request auto-approvable or satisfy the session-scoped
			// affordance, both of which match against the documented vocabulary only.
			options.append(ACPPermissionOption(optionID: optionID, kind: optionKind))
		}

		// rawInput is size-checked BEFORE a huge string is ever built (finding 4): the
		// bounded serializer short-circuits once the estimated byte size exceeds the
		// bound and drops the field to a short marker rather than allocating then
		// truncating a multi-megabyte string.
		let rawInputJSON = ACPBoundedJSON.serialized(
			toolCall["rawInput"],
			byteLimit: ACPPermissionBounds.rawInputJSONBytes
		)

		return .success(ACPPermissionRequest(
			rpcID: id,
			storageKey: id.storageKey,
			sessionID: sessionID,
			toolCallID: toolCallID,
			toolTitle: toolTitle,
			toolKind: toolKind,
			rawInputJSON: rawInputJSON,
			options: options,
			sessionScopedOptionID: ACPPermissionPolicy.optionID(for: options, preferences: policy.sessionAffordance)
		))
	}

}
