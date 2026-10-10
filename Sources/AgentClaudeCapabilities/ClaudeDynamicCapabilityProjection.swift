import Foundation

// Item 10 — dynamic capability gating (plan §6).
//
//     effectiveModels = staticConservativeCatalog ∩ parse(modelsJSON)
//     effectiveModels = staticConservativeCatalog          // parse fails or absent
//
// INTERSECTION, NEVER UNION. A runtime advertising a model the app has no code for
// does not make it selectable. This is the whole point of the rule and the reason
// the fallback is the STATIC catalog rather than the parsed one: every failure mode
// — absent field, malformed JSON, unknown shape, unrecognised entries — lands on
// what the app already supports, never on what the runtime claims.
//
// Everything here is PURE and SESSION-SCOPED. The result is carried inside
// `ClaudeSessionCapabilityProjection`, which the controller holds in actor memory
// for one epoch and clears at both epoch start and teardown. Nothing in this file
// touches a persistence API (R15f), and there is no second child, probe, timeout or
// request: the only input is the initialize snapshot the production child already
// produced.

// MARK: - Fast-mode state

/// The runtime's fast-mode state, as observed at initialize.
///
/// `.unknown` is deliberately distinct from `.disabled`: "the runtime did not tell
/// us" and "the runtime told us it is off" are different facts, and collapsing them
/// would let a parse failure read as a positive observation. Both are treated
/// conservatively (fast mode is not offered), but only one is a diagnostic.
public enum ClaudeFastModeState: Equatable, Sendable {
	case unknown
	case disabled
	case enabled

	public var isOffered: Bool { self == .enabled }
}

// MARK: - Diagnostics

/// Why a dynamic projection fell back.
///
/// Deliberately carries NO runtime payload — no raw JSON, no model names from the
/// runtime, no account or environment data (§8). Shapes and counts only, so a
/// diagnostic can never become an exfiltration path for the very fields Program B
/// spent eleven commits isolating.
public enum ClaudeDynamicCapabilityDiagnostic: Equatable, Sendable, CustomStringConvertible {
	/// The field was absent from the initialize response.
	case modelsAbsent
	/// The field was present but could not be parsed into a list of model names.
	case modelsUnparseable
	/// Parsed successfully, but every advertised entry was unknown to the app. The
	/// intersection is EMPTY and that is the result — the static catalog is not
	/// restored, because restoring it would offer models the runtime never advertised.
	case modelsIntersectionEmpty(advertised: Int)
	/// Parsed successfully; some advertised entries are unknown to the app and were
	/// DROPPED. Recorded because it is the intersection doing its job, and a rising
	/// count is how a runtime/app divergence becomes visible.
	case modelsDroppedUnknown(count: Int)
	case fastModeAbsent
	case fastModeUnparseable
	/// An effort value was present but is not one the app implements.
	case effortUnrecognized

	public var description: String {
		switch self {
		case .modelsAbsent: return "models: absent; static catalog stands"
		case .modelsUnparseable: return "models: unparseable; static catalog stands"
		case let .modelsIntersectionEmpty(advertised):
			return "models: \(advertised) advertised, none known to this app; intersection is empty"
		case let .modelsDroppedUnknown(count):
			return "models: \(count) advertised entr\(count == 1 ? "y" : "ies") unknown to this app, dropped"
		case .fastModeAbsent: return "fast_mode_state: absent; fast mode not offered"
		case .fastModeUnparseable: return "fast_mode_state: unparseable; fast mode not offered"
		case .effortUnrecognized: return "effort: unrecognised value; conservative default applied"
		}
	}
}

// MARK: - The projection

/// What the runtime and the app AGREE this session can do.
public struct ClaudeDynamicCapabilities<Effort: Equatable & Sendable>: Equatable, Sendable {

	/// Whether the runtime narrowed the static catalog, or the static catalog stands
	/// unchanged. Never "the runtime widened it" — that case does not exist.
	public enum Source: Equatable, Sendable {
		/// The runtime advertised a parseable list and the result is the intersection.
		case runtimeIntersected
		/// Absent, malformed, or unusable input — the conservative static catalog.
		case staticFallback
	}

	public let effectiveModels: [String]
	public let modelsSource: Source
	public let effectiveEffortLevels: [Effort]
	public let fastMode: ClaudeFastModeState
	public let diagnostics: [ClaudeDynamicCapabilityDiagnostic]

    public init(effectiveModels: [String], modelsSource: Source, effectiveEffortLevels: [Effort],
                fastMode: ClaudeFastModeState, diagnostics: [ClaudeDynamicCapabilityDiagnostic]) {
        self.effectiveModels = effectiveModels; self.modelsSource = modelsSource
        self.effectiveEffortLevels = effectiveEffortLevels; self.fastMode = fastMode
        self.diagnostics = diagnostics
    }

	/// The inert value: the static catalog, nothing observed. Used when there is no
	/// initialize snapshot to read.
	public static func staticOnly(
		models: [String],
		effortLevels: [Effort]
	) -> ClaudeDynamicCapabilities<Effort> {
		ClaudeDynamicCapabilities(
			effectiveModels: models, modelsSource: .staticFallback,
			effectiveEffortLevels: effortLevels, fastMode: .unknown, diagnostics: [])
	}
}

// MARK: - The projector

public enum ClaudeDynamicCapabilityProjector<Effort: Equatable & Sendable> {

	/// Project the initialize snapshot onto this session's effective capabilities.
	///
	/// - Parameters:
	///   - staticModelCatalog: what the app has code for. AUTHORITATIVE — the result
	///     is always a subset of this, in this order.
	///   - staticEffortCatalog: likewise for effort levels.
	///   - modelsValue: the raw `models` value from the initialize response, exactly
	///     as the production child produced it. Never re-requested.
	///   - fastModeStateValue: the raw `fast_mode_state` value, likewise.
	public static func project(
		staticModelCatalog: [String],
		staticEffortCatalog: [Effort],
		modelsValue: Any?,
		fastModeStateValue: Any?,
		parseEffort: (String) -> Effort?
	) -> ClaudeDynamicCapabilities<Effort> {
		var diagnostics: [ClaudeDynamicCapabilityDiagnostic] = []

		// --- Models -----------------------------------------------------------
		let advertised = parseModelNames(modelsValue)
		let effectiveModels: [String]
		let modelsSource: ClaudeDynamicCapabilities<Effort>.Source

		switch advertised {
		case .none:
			diagnostics.append(modelsValue == nil ? .modelsAbsent : .modelsUnparseable)
			effectiveModels = staticModelCatalog
			modelsSource = .staticFallback
		case .some(let names):
			// THE INTERSECTION. Iterating the STATIC catalog (not the advertised list)
			// is what makes union impossible by construction: an advertised name the
			// app does not know can never be appended, only matched or ignored.
			let advertisedSet = Set(names.map { normalized($0) })
			let intersection = staticModelCatalog.filter { advertisedSet.contains(normalized($0)) }

			// AN EMPTY INTERSECTION IS THE ANSWER, not a reason to fall back.
			//
			// A previous revision restored the full static catalog here, reasoning that a
			// runtime sharing no model with the app was more likely a misread shape than a
			// genuine "offer nothing". That was wrong, and wrong in the one direction this
			// rule exists to prevent: it OFFERED MODELS THE RUNTIME NEVER ADVERTISED,
			// turning a successful parse into a widening. The parse succeeded — the app
			// knows exactly what was advertised and that it overlaps with nothing. Static
			// fallback is reserved for the cases where the app knows NOTHING: absent or
			// unparseable input.
			if intersection.isEmpty {
				diagnostics.append(.modelsIntersectionEmpty(advertised: names.count))
			}
			let knownSet = Set(staticModelCatalog.map { normalized($0) })
			let dropped = advertisedSet.subtracting(knownSet).count
			if dropped > 0 { diagnostics.append(.modelsDroppedUnknown(count: dropped)) }
			effectiveModels = intersection
			modelsSource = .runtimeIntersected
		}

		// --- Fast mode --------------------------------------------------------
		let fastMode: ClaudeFastModeState
		if fastModeStateValue == nil {
			diagnostics.append(.fastModeAbsent)
			fastMode = .unknown
		} else if let parsed = parseFastMode(fastModeStateValue) {
			fastMode = parsed
		} else {
			diagnostics.append(.fastModeUnparseable)
			fastMode = .unknown
		}

		// --- Effort -----------------------------------------------------------
		// The certified initialize response advertises no effort catalog (§0.4), so
		// the static catalog stands. An effort value carried inside `fast_mode_state`
		// is read defensively: recognised values are kept, unrecognised ones fall back
		// to the full static catalog with a diagnostic — never to an empty set, and
		// never to a level the app has not implemented.
		var effectiveEffortLevels = staticEffortCatalog
		if let rawEffort = parseEffortHint(fastModeStateValue) {
			if let level = parseEffort(rawEffort), staticEffortCatalog.contains(level) {
				effectiveEffortLevels = [level]
			} else {
				diagnostics.append(.effortUnrecognized)
			}
		}

		return ClaudeDynamicCapabilities(
			effectiveModels: effectiveModels,
			modelsSource: modelsSource,
			effectiveEffortLevels: effectiveEffortLevels,
			fastMode: fastMode,
			diagnostics: diagnostics)
	}

	// MARK: - Parsing

	private static func normalized(_ name: String) -> String {
		name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}

	/// The exact shape of `models` is NOT recorded anywhere this workstream has
	/// verified — the interrupt spike observed the FIELD, not its contents. So this
	/// accepts the plausible shapes and returns `nil` for anything else.
	///
	/// Being wrong about the shape is SAFE by construction: `nil` means "static
	/// catalog stands". A parser that guessed generously would be the dangerous
	/// direction, because a wrong guess there widens what is offered.
	public static func parseModelNames(_ value: Any?) -> [String]? {
		guard let value else { return nil }

		// A JSON string carrying the payload (the canonicalized `modelsJSON` form).
		if let string = value as? String {
			guard let data = string.data(using: .utf8),
				  let decoded = try? JSONSerialization.jsonObject(with: data) else { return nil }
			return parseModelNames(decoded)
		}
		// ["opus", "sonnet"]
		if let strings = value as? [String] {
			let cleaned = strings.filter { !normalized($0).isEmpty }
			return cleaned.isEmpty ? nil : cleaned
		}
		// [{"model": "opus"}, {"id": …}, {"name": …}]
		if let objects = value as? [[String: Any]] {
			let names = objects.compactMap { entry -> String? in
				for key in ["model", "id", "name", "value"] {
					if let name = entry[key] as? String, !normalized(name).isEmpty { return name }
				}
				return nil
			}
			return names.isEmpty ? nil : names
		}
		// {"models": [...]} — a wrapper object.
		if let object = value as? [String: Any] {
			for key in ["models", "available", "supported"] {
				if let nested = object[key], let names = parseModelNames(nested) { return names }
			}
			return nil
		}
		return nil
	}

	public static func parseFastMode(_ value: Any?) -> ClaudeFastModeState? {
		guard let value else { return nil }
		if let string = value as? String {
			if let data = string.data(using: .utf8),
			   let decoded = try? JSONSerialization.jsonObject(with: data) {
				return parseFastMode(decoded)
			}
			switch normalized(string) {
			case "enabled", "on", "true": return .enabled
			case "disabled", "off", "false": return .disabled
			default: return nil
			}
		}
		if let flag = value as? Bool { return flag ? .enabled : .disabled }
		if let object = value as? [String: Any] {
			for key in ["enabled", "active", "isEnabled"] {
				if let flag = object[key] as? Bool { return flag ? .enabled : .disabled }
			}
			if let state = object["state"] as? String { return parseFastMode(state) }
			return nil
		}
		return nil
	}

	/// An effort hint carried inside `fast_mode_state`, if any. Returns the RAW
	/// string; recognising it is the caller's job.
	public static func parseEffortHint(_ value: Any?) -> String? {
		guard let object = value as? [String: Any] else {
			guard let string = value as? String,
				  let data = string.data(using: .utf8),
				  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
			else { return nil }
			return parseEffortHint(decoded)
		}
		for key in ["effort", "effortLevel", "effort_level"] {
			if let raw = object[key] as? String, !normalized(raw).isEmpty { return raw }
		}
		return nil
	}
}
