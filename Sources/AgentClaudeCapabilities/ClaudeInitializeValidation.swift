import Foundation

// Item 7, phases B and C — the PURE pieces of post-initialize admission and
// capability projection. No I/O, no lifecycle, no turn state.
//
// Phase B (final admission) observes ONLY what the production child has already
// produced by the post-initialize point, using the existing child, the existing
// initialize response, the existing `InitializeTimeoutPolicy`, and the existing
// `set_permission_mode` round trip. It adds no second child, no second initialize,
// no second timeout, and no duplicate permission request.
//
// It does NOT require a session id and does NOT consult `system/init`: per the
// item-2 canary, `session_id` and `capabilities` first appear in `system/init`,
// which the CLI emits only AFTER a user message begins. Requiring either would
// deadlock pre-turn admission — `startOrResume` must return before a message can be
// sent — or reject every certified fresh launch.
//
// Phase C (capability settle) turns the FINAL evaluation into what the session
// offers. It reads the matched family's per-capability state only; it never parses
// `modelsJSON` or `fastModeStateJSON` (that dynamic intersection is item 10) and it
// never persists anything.

// MARK: - Phase B: initialize-response well-formedness

/// The structural predicate behind `ClaudeBehavioralValidator`'s
/// `initializeResponseWellFormed` input.
///
/// `parseInitializeResponseSnapshot` is TOTAL — it maps any dictionary, including an
/// empty one, to a snapshot with empty fields — so the snapshot alone cannot answer
/// "was the response well formed?". This predicate answers it from the raw decoded
/// control response, which is the only pre-turn evidence available.
///
/// A TYPED MINIMUM CONTRACT, pinned to the certified captures — not a key-presence
/// sniff.
///
/// The first version asked only "is at least one recognised key present?", which
/// `["pid": 1]` satisfies, and which any key with any value type satisfies. That is
/// close enough to vacuous to be misleading: it would certify a runtime whose
/// initialize response is structurally unusable.
///
/// The contract below is taken from the interrupt-certification spike's direct
/// observation of the certified 2.1.215/2.1.216 `initialize` control response
/// (spike report §4.2), which carries:
///
///     account, agents, available_output_styles, commands, ide_rc_auto_enable_gate,
///     models, output_style, pid, remote_control_auto_enable,
///     remote_control_auto_on_by_default
///
/// — and NO `capabilities` and NO `session_id`.
///
/// Two rules, both load-bearing:
///   1. REQUIRED fields must be present AND correctly typed. These four are the
///      ones the app actually consumes downstream, so a response missing or
///      mistyping any of them is not usable regardless of what else it carries.
///   2. OPTIONAL recognised fields, when present, must ALSO be correctly typed. A
///      `pid` of `"4242"` is a protocol change, not field churn, and silently
///      accepting it is how a mistyped field reaches a consumer that force-casts.
///
/// Fields outside both sets are ignored, so additive runtime churn stays harmless.
public enum ClaudeInitializeResponseWellFormedness {

	/// What a well-formed response must carry. Deliberately does NOT include
	/// `account` (privacy-sensitive and legitimately absent under some auth modes),
	/// `models`/`fast_mode_state` (item 10 owns those), or the `ide_rc_*` /
	/// `remote_control_*` flags (peripheral, and most likely to churn).
	public static let requiredFields: Set<String> = [
		"commands", "output_style", "available_output_styles", "pid"
	]

	/// Recognised but not required. Type-checked when present.
	public static let optionalTypedFields: Set<String> = [
		"agents", "account", "models", "fast_mode_state"
	]

	public static var recognizedFields: Set<String> { requiredFields.union(optionalTypedFields) }

	/// Why a response failed, so a diagnostic can name the field rather than saying
	/// "malformed".
	public enum Violation: Equatable, Sendable {
		case empty
		case missingRequiredField(String)
		case wrongType(field: String, expected: String)
	}

	public static func violations(of response: [String: Any]) -> [Violation] {
		guard !response.isEmpty else { return [.empty] }
		var found: [Violation] = []

		for field in requiredFields.sorted() where response[field] == nil {
			found.append(.missingRequiredField(field))
		}
		for (field, expected) in typeExpectations.sorted(by: { $0.key < $1.key }) {
			guard let value = response[field] else { continue }
			if !expected.matches(value) {
				found.append(.wrongType(field: field, expected: expected.description))
			}
		}
		return found
	}

	public static func isWellFormed(_ response: [String: Any]) -> Bool {
		violations(of: response).isEmpty
	}

	// MARK: - Type expectations

	/// Each expectation mirrors EXACTLY what `parseInitializeResponseSnapshot`
	/// requires to actually consume the field.
	///
	/// A looser expectation is not "lenient", it is wrong: the validator would certify
	/// a response the production parser silently discards. `available_output_styles:
	/// [1]` type-casts to `[Any]` but the parser asks for `[String]` and falls back to
	/// `[]`; `agents: [1]` is an array but the parser asks for `[[String: Any]]`;
	/// `commands: [[:]]` is an array of objects whose every entry the parser drops for
	/// lacking a non-empty `name`. Each of those is a runtime the app cannot read,
	/// reported as well formed.
	public enum Expectation: CustomStringConvertible, Sendable {
		case arrayOfStrings
		/// Array of objects, each carrying a non-empty `name` string — the parser's
		/// `compactMap` guard. An array whose entries are ALL discarded is not a
		/// usable field.
		case arrayOfNamedObjects
		case string
		case positiveInt
		case object
		/// Present but unconstrained — `models` and `fast_mode_state` are shaped by
		/// the runtime and parsed by item 10, never here.
		case anyValue

		public var description: String {
			switch self {
			case .arrayOfStrings: return "array of strings"
			case .arrayOfNamedObjects: return "array of objects each with a non-empty name"
			case .string: return "string"
			case .positiveInt: return "positive integer"
			case .object: return "object"
			case .anyValue: return "any"
			}
		}

		func matches(_ value: Any) -> Bool {
			switch self {
			case .arrayOfStrings:
				return value is [String]
			case .arrayOfNamedObjects:
				guard let entries = value as? [[String: Any]] else { return false }
				// An EMPTY array is acceptable (a runtime may expose no agents); an
				// array of unusable entries is not.
				return entries.allSatisfy { entry in
					guard let name = entry["name"] as? String else { return false }
					return !name.isEmpty
				}
			case .string: return value is String
			case .positiveInt:
				// `Bool` bridges to `NSNumber`, so a bare `is Int` check would accept
				// `true`. Reject it explicitly.
				if value is Bool { return false }
				guard let number = value as? Int else { return false }
				return number > 0
			case .object: return value is [String: Any]
			case .anyValue: return true
			}
		}
	}

	static let typeExpectations: [String: Expectation] = [
		"commands": .arrayOfNamedObjects,
		"output_style": .string,
		"available_output_styles": .arrayOfStrings,
		"pid": .positiveInt,
		"agents": .arrayOfNamedObjects,
		"account": .object,
		"models": .anyValue,
		"fast_mode_state": .anyValue,
	]
}

// MARK: - Phase B: the permission-mode round trip

/// The observed outcome of the post-initialize `set_permission_mode` control
/// request — richer than a Bool, because "the request returned success" and "the
/// runtime is in the mode we asked for" are different claims.
///
/// The first version collapsed them: ANY successful control response counted as a
/// round trip, so a success payload reporting `acceptEdits` after `default` was
/// requested would have certified. That is the §5.2 hole reappearing one level
/// down — argv and the control request agree, and the RUNTIME still disagrees with
/// both.
public enum ClaudePermissionModeRoundTrip: Equatable, Sendable {
	/// No request was built (an empty effective mode). Never a pass.
	case notAttempted
	/// Success, and the response echoed the mode we requested.
	case confirmed(mode: String)
	/// Success, but the payload carried no `mode` to compare — so runtime agreement
	/// is UNPROVEN.
	///
	/// This FAILS validation. Both certified runtimes (2.1.215 and 2.1.216) echo the
	/// mode, observed directly in Gate-2 lane 2, so a missing echo is a departure from
	/// the certified contract rather than an unremarkable shape difference. Treating
	/// it as a pass would let the one case where agreement is unobservable be the one
	/// case that certifies. Stage 0 stays inert regardless: it records the failed
	/// validation and still admits.
	case succeededWithoutEcho(requested: String)
	/// Success, but the runtime reports a DIFFERENT mode. A real failure.
	case modeMismatch(requested: String, returned: String)

	/// What §3.1 consumes. ONLY a confirmed echo proves the runtime agreed.
	public var satisfiesValidation: Bool {
		switch self {
		case .confirmed: return true
		case .notAttempted, .succeededWithoutEcho, .modeMismatch: return false
		}
	}

	/// Classify a control response against the mode that was requested.
	public static func classify(requestedMode: String, response: [String: Any]) -> ClaudePermissionModeRoundTrip {
		guard let returned = response["mode"] as? String else {
			return .succeededWithoutEcho(requested: requestedMode)
		}
		guard returned.caseInsensitiveCompare(requestedMode) == .orderedSame else {
			return .modeMismatch(requested: requestedMode, returned: returned)
		}
		return .confirmed(mode: returned)
	}
}

