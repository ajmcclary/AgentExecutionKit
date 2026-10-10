import Foundation
import ClaudeRuntimeKit

// MARK: - Phase C: session-scoped capability projection

/// What THIS session offers, derived once from the final admission. Session-scoped
/// and non-persisted by construction: it is a plain value held by the controller
/// actor for the epoch's lifetime, with no `UserDefaults`, file, or keychain path
/// (R15f).
///
/// Interrupt is NOT in the offered set. It is a safety PRECONDITION (§3.2): an
/// uncertified interrupt forces reject/external-only under enforcement rather than
/// merely being an unoffered feature. It is surfaced here as a recorded precondition
/// state so stage-0 observation can see an uncertified runtime that was nonetheless
/// admitted inertly.
public struct ClaudeSessionCapabilityProjection<Effort: RawRepresentable & Equatable & Sendable>: Equatable, Sendable where Effort.RawValue == String {

	/// `nil` model/effort catalogs mean "no manifest restriction" — the stage-0 /
	/// `.admitUnrestricted` case, where requested behaviour is preserved intact.
	/// A non-nil catalog is the family's CERTIFIED list and is authoritative.
	public enum Restriction: Equatable, Sendable {
		/// Stage 0, and stage 1 before §5.3: requested behaviour preserved. This is
		/// what keeps observe-only inert.
		case unrestricted
		/// Stage ≥ 2 with a bound family: only what the family certifies is offered.
		case certifiedOnly(ClaudeOfferedCapabilities)
	}

	public let restriction: Restriction
	/// The matched family's interrupt state — a precondition, never an offered feature.
	public let interruptPrecondition: ClaudeCapabilityState
	public let limitations: [String]
	/// Session-scoped effective model/effort carried from the epoch's admitted launch.
	/// Never written to `UserDefaults` or any cross-session cache (§9.1.13).
	public let sessionModel: String?
	public let sessionEffortLevel: Effort?

	/// Item 10 — what the RUNTIME and the app agree this session can do (§6).
	///
	/// Lives INSIDE the session projection deliberately. The projection is already
	/// the one value the controller clears at both epoch start and teardown, and is
	/// already the closed, count-ratcheted boundary R15f enforces. Giving the
	/// dynamic capabilities their own controller-held variable would have created a
	/// second lifetime to keep in sync — and a second thing to forget to clear.
	public let dynamic: ClaudeDynamicCapabilities<Effort>

    public init(restriction: Restriction, interruptPrecondition: ClaudeCapabilityState,
                limitations: [String], sessionModel: String?, sessionEffortLevel: Effort?,
                dynamic: ClaudeDynamicCapabilities<Effort>) {
        self.restriction = restriction; self.interruptPrecondition = interruptPrecondition
        self.limitations = limitations; self.sessionModel = sessionModel
        self.sessionEffortLevel = sessionEffortLevel; self.dynamic = dynamic
    }

	/// True only when the matched family certifies interrupt. Under enforcement this
	/// is always true (admission rejected otherwise); at stage 0 it may be false and
	/// is recorded rather than acted upon.
	public var interruptSafetyPreconditionSatisfied: Bool { interruptPrecondition == .certified }

	public var offersResume: Bool {
		switch restriction {
		case .unrestricted: return true
		case .certifiedOnly(let offered): return offered.resume
		}
	}

	public var offersStructuredOutput: Bool {
		switch restriction {
		case .unrestricted: return true
		case .certifiedOnly(let offered): return offered.structuredOutput
		}
	}

	/// `nil` = unrestricted. A non-nil (possibly EMPTY) array is the certified
	/// catalog — an empty certified catalog offers nothing, which is not the same as
	/// "no restriction".
	public var offeredModels: [String]? {
		switch restriction {
		case .unrestricted: return nil
		case .certifiedOnly(let offered): return offered.models
		}
	}

	public var offeredEffortLevels: [String]? {
		switch restriction {
		case .unrestricted: return nil
		case .certifiedOnly(let offered): return offered.effortLevels
		}
	}

	// MARK: - The production consumer (item 10)

	/// Whether a requested model / effort may be applied to THIS session.
	///
	/// Item 10 computed a projection that nothing read: `currentCapabilityProjection`
	/// was assigned and then observed only by a test accessor, so no model, effort, or
	/// fast-mode availability was actually gated. Computing a restriction and not
	/// applying it is indistinguishable from not having one.
	///
	/// STAGE 0 IS INERT, BY THE FIRST BRANCH. Under `.observeOnly` every request is
	/// admitted unchanged and the reason is recorded for telemetry, so the §9.1.9
	/// inertness assertions still hold: same argv, same environment, same control
	/// requests.
	public enum CapabilityAdmission: Equatable, Sendable {
		case allowed
		/// Stage 0 only: the request would have been refused under enforcement. Applied
		/// anyway; recorded so observe-only can measure what enforcement would do.
		case allowedObservedOnly(reason: Refusal)
		case refused(Refusal)

		public enum Refusal: Equatable, Sendable, CustomStringConvertible {
			case modelNotOffered(requested: String)
			case effortNotOffered(requested: String)

			public var description: String {
				switch self {
				case let .modelNotOffered(requested):
					return "model \(requested.debugDescription) is not offered by this session"
				case let .effortNotOffered(requested):
					return "effort \(requested.debugDescription) is not offered by this session"
				}
			}
		}

		public var isRefused: Bool { if case .refused = self { return true }; return false }
	}

	/// - Parameter stage: the epoch's enforcement stage. `.observeOnly` never refuses.
	public func admits(
		model: String?,
		effortLevel: Effort?,
		stage: ClaudeAdmissionEnforcementStage
	) -> CapabilityAdmission {
		func normalized(_ value: String) -> String {
			value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		}

		var refusal: CapabilityAdmission.Refusal?
		if let model, !model.isEmpty {
			let offered = Set(dynamic.effectiveModels.map(normalized))
			// A model specifier may carry an effort suffix (`opus:high`); gate on the
			// model component, which is what the catalog names.
			let base = normalized(model.split(separator: ":").first.map(String.init) ?? model)
			if !offered.contains(base) { refusal = .modelNotOffered(requested: model) }
		}
		if refusal == nil, let effortLevel, !dynamic.effectiveEffortLevels.contains(effortLevel) {
			refusal = .effortNotOffered(requested: effortLevel.rawValue)
		}

		guard let refusal else { return .allowed }
		switch stage {
		case .observeOnly, .enforceKnownBad:
			// §7.2: stage 1 rejects known-bad / external-only / uncertified-interrupt /
			// unresolvable identities — it does NOT restrict capabilities. Capability
			// restriction is §5.3, which arrives at stage 2. Refusing here would be a
			// behaviour change at stage 1 that the plan does not authorise, so stage 1
			// observes exactly as stage 0 does.
			return .allowedObservedOnly(reason: refusal)
		case .enforceLimited, .enforceAll:
			return .refused(refusal)
		}
	}

	/// Project the final admission onto session capabilities. Reads the DECISION (so
	/// the per-capability `uncertified` state that `ClaudeOfferedCapabilities.project`
	/// already applied is preserved) and never the raw family classification — a
	/// `supported` family with `resume: uncertified` must not offer resume (§9.1.16).
	/// - Parameters:
	///   - staticModelCatalog: the models the app has code for — item 10's
	///     conservative catalog, and the authoritative upper bound.
	///   - modelsValue / fastModeStateValue: the raw initialize-response values the
	///     production child already produced. No second child, probe, timeout or
	///     request is issued to obtain them (§6).
	public static func project(
		evaluation: ClaudeAdmissionEvaluation,
		sessionModel: String?,
		sessionEffortLevel: Effort?,
		staticModelCatalog: [String],
		staticEffortCatalog: [Effort],
		modelsValue: Any?,
		fastModeStateValue: Any?,
		parseEffort: (String) -> Effort?
	) -> ClaudeSessionCapabilityProjection {
		let restriction: Restriction
		switch evaluation.decision {
		case .admitUnrestricted:
			restriction = .unrestricted
		case .admitFull(let offered):
			restriction = .certifiedOnly(offered)
		case .admitLimited(_, let offered, _):
			restriction = .certifiedOnly(offered)
		case .reject:
			// Unreachable: a rejection throws before phase C. Fail closed anyway.
			restriction = .certifiedOnly(.none)
		}

		// Item 10's conservative base, computed BEFORE the runtime is consulted.
		//
		// When the decision restricts to a certified catalog, that catalog is
		// intersected with the app's own — certification cannot introduce a model the
		// app has no code for, any more than the runtime can. The runtime intersection
		// then narrows this further. Three intersections, never a union at any step.
		let certifiedModels: [String]?
		let certifiedEffortLevels: [String]?
		switch restriction {
		case .unrestricted:
			certifiedModels = nil
			certifiedEffortLevels = nil
		case .certifiedOnly(let offered):
			certifiedModels = offered.models
			certifiedEffortLevels = offered.effortLevels
		}

		func normalized(_ value: String) -> String {
			value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		}

		let modelBase: [String]
		if let certifiedModels {
			let certifiedSet = Set(certifiedModels.map(normalized))
			modelBase = staticModelCatalog.filter { certifiedSet.contains(normalized($0)) }
		} else {
			modelBase = staticModelCatalog
		}

		// EFFORT IS BOUNDED THE SAME WAY AS MODELS.
		//
		// It previously was not: the full app effort catalog went straight through while
		// models were narrowed to certification. Both certified families today certify an
		// EMPTY effort list, so that asymmetry offered every effort level the app
		// implements under a restriction that certified none of them. An empty certified
		// effort list means "no effort level is certified", exactly as an empty certified
		// model list means "no model is certified" — neither is a licence to fall back.
		let effortBase: [Effort]
		if let certifiedEffortLevels {
			let certifiedSet = Set(certifiedEffortLevels.map(normalized))
			effortBase = staticEffortCatalog.filter { certifiedSet.contains(normalized($0.rawValue)) }
		} else {
			effortBase = staticEffortCatalog
		}

		let dynamic = ClaudeDynamicCapabilityProjector.project(
			staticModelCatalog: modelBase,
			staticEffortCatalog: effortBase,
			modelsValue: modelsValue,
			fastModeStateValue: fastModeStateValue, parseEffort: parseEffort)

		return ClaudeSessionCapabilityProjection(
			restriction: restriction,
			interruptPrecondition: evaluation.assessment.interrupt,
			limitations: evaluation.assessment.limitations,
			sessionModel: sessionModel,
			sessionEffortLevel: sessionEffortLevel,
			dynamic: dynamic)
	}
}
