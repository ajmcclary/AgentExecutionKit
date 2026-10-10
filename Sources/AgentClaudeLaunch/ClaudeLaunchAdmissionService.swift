import Foundation
import ClaudeRuntimeKit

public struct ClaudeAdmissionLaunchGate {
	public let coordinator: ClaudeAdmissionCoordinator
	public let stage: ClaudeAdmissionEnforcementStage
	public init(coordinator: ClaudeAdmissionCoordinator, stage: ClaudeAdmissionEnforcementStage) { self.coordinator = coordinator; self.stage = stage }
	public enum Action: Equatable, Sendable {
		case proceed(evaluation: ClaudeAdmissionEvaluation, evaluateCycleGuard: Bool)
		case reject(reason: ClaudeAdmissionRejectReason, evaluation: ClaudeAdmissionEvaluation)
	}
	public func decidePrelaunch(_ query: ClaudePrelaunchQuery) -> Action {
		let evaluation = coordinator.evaluatePrelaunch(query, stage: stage)
		switch evaluation.decision {
		case .reject(let reason): return .reject(reason: reason, evaluation: evaluation)
		case .admitUnrestricted, .admitFull, .admitLimited: return .proceed(evaluation: evaluation, evaluateCycleGuard: stage != .observeOnly)
		}
	}
}
public enum ClaudeLaunchCycleGuardState: Equatable, Sendable { case notEvaluatedObserveOnly, matched }
public struct ClaudePolicyIndependentLaunch<Provenance: Equatable & Sendable>: Sendable {
	public let command: String
	public let runtimeResolution: ClaudeRuntimeResolution
	public let launchProfileKey: ClaudeLaunchProfileKey
	public let workingDirectory: String
	public let provenance: Provenance
	public init(command: String, runtimeResolution: ClaudeRuntimeResolution, launchProfileKey: ClaudeLaunchProfileKey, workingDirectory: String, provenance: Provenance) {
		self.command = command; self.runtimeResolution = runtimeResolution; self.launchProfileKey = launchProfileKey
		self.workingDirectory = workingDirectory; self.provenance = provenance
	}
}
public struct ClaudeResolvedLaunch<Context: Sendable, Effort: RawRepresentable & Equatable & Sendable>: Sendable where Effort.RawValue == String {
	public let plan: ClaudeNativeLaunchPlan<Context>
	public let runtimeResolution: ClaudeRuntimeResolution
	public let launchProfileKey: ClaudeLaunchProfileKey
	public let prelaunchEvaluation: ClaudeAdmissionEvaluation
	public let cycleGuard: ClaudeLaunchCycleGuardState
	public let effectiveKnobs: ClaudeLaunchEffectiveKnobs<Effort>
}

/// Owns phase-A ordering, early rejection, effective knobs and both cycle checks.
/// Host ports produce backend/authentication evidence and actual executable plans;
/// the service performs no implicit filesystem, credential or setting lookup.
public struct ClaudeLaunchAdmissionService<Context: Sendable, Effort: RawRepresentable & Equatable & Sendable, Provenance: Equatable & Sendable> where Effort.RawValue == String {
	public struct Errors: Sendable {
		public let rejected: @Sendable (ClaudeAdmissionRejectReason) -> any Error
		public let provenanceDrift: @Sendable () -> any Error
		public let cycleGuardDiverged: @Sendable () -> any Error
		public init(rejected: @escaping @Sendable (ClaudeAdmissionRejectReason) -> any Error,
			provenanceDrift: @escaping @Sendable () -> any Error, cycleGuardDiverged: @escaping @Sendable () -> any Error) {
			self.rejected = rejected; self.provenanceDrift = provenanceDrift; self.cycleGuardDiverged = cycleGuardDiverged
		}
	}
	public enum Event: Sendable { case rejected(ClaudeAdmissionRejectReason); case provenanceDrift; case cycleGuardDiverged }
	public struct Collaborators {
		public let buildRequested: () async throws -> ClaudeNativeLaunchPlan<Context>
		public let resolveIdentity: (String) -> ClaudeRuntimeResolution
		public let requestedProfile: (ClaudeNativeLaunchPlan<Context>) -> ClaudeLaunchProfileKey
		public let prepareIndependent: () async throws -> ClaudePolicyIndependentLaunch<Provenance>
		public let resolveEffectiveFlags: (ClaudeLaunchEffectiveKnobs<Effort>) async throws -> ClaudeLaunchFlagResolution<Context>
		public let provenance: (Context) -> Provenance
		public let buildEffective: (ClaudeLaunchEffectiveKnobs<Effort>, ClaudeLaunchFlagResolution<Context>, String) async throws -> ClaudeNativeLaunchPlan<Context>
		public init(buildRequested: @escaping () async throws -> ClaudeNativeLaunchPlan<Context>,
			resolveIdentity: @escaping (String) -> ClaudeRuntimeResolution, requestedProfile: @escaping (ClaudeNativeLaunchPlan<Context>) -> ClaudeLaunchProfileKey,
			prepareIndependent: @escaping () async throws -> ClaudePolicyIndependentLaunch<Provenance>,
			resolveEffectiveFlags: @escaping (ClaudeLaunchEffectiveKnobs<Effort>) async throws -> ClaudeLaunchFlagResolution<Context>,
			provenance: @escaping (Context) -> Provenance,
			buildEffective: @escaping (ClaudeLaunchEffectiveKnobs<Effort>, ClaudeLaunchFlagResolution<Context>, String) async throws -> ClaudeNativeLaunchPlan<Context>) {
			self.buildRequested = buildRequested; self.resolveIdentity = resolveIdentity; self.requestedProfile = requestedProfile
			self.prepareIndependent = prepareIndependent; self.resolveEffectiveFlags = resolveEffectiveFlags
			self.provenance = provenance; self.buildEffective = buildEffective
		}
	}
	private let collaborators: Collaborators
	private let errors: Errors
	public init(collaborators: Collaborators, errors: Errors) { self.collaborators = collaborators; self.errors = errors }
	public nonisolated(nonsending) func resolve(stage: ClaudeAdmissionEnforcementStage, coordinator: ClaudeAdmissionCoordinator,
		requested: ClaudeLaunchEffectiveKnobs<Effort>, observe: (Event) -> Void) async throws -> ClaudeResolvedLaunch<Context, Effort> {
		let gate = ClaudeAdmissionLaunchGate(coordinator: coordinator, stage: stage)
		if stage == .observeOnly {
			let plan = try await collaborators.buildRequested()
			let resolution = collaborators.resolveIdentity(plan.resolvedCommand)
			let key = collaborators.requestedProfile(plan)
			switch gate.decidePrelaunch(Self.query(resolution, key)) {
			case .reject(let reason, _): throw errors.rejected(reason)
			case .proceed(let evaluation, let evaluateCycleGuard):
				return .init(plan: plan, runtimeResolution: resolution, launchProfileKey: key, prelaunchEvaluation: evaluation,
					cycleGuard: evaluateCycleGuard ? .matched : .notEvaluatedObserveOnly, effectiveKnobs: Self.effective(evaluation, requested))
			}
		}
		let independent = try await collaborators.prepareIndependent()
		switch gate.decidePrelaunch(Self.query(independent.runtimeResolution, independent.launchProfileKey)) {
		case .reject(let reason, _): observe(.rejected(reason)); throw errors.rejected(reason)
		case .proceed(let evaluation, let evaluateCycleGuard):
			let knobs = Self.effective(evaluation, requested)
			let flags = try await collaborators.resolveEffectiveFlags(knobs)
			guard collaborators.provenance(flags.launchEnvironment) == independent.provenance else {
				observe(.provenanceDrift); throw errors.provenanceDrift()
			}
			let plan = try await collaborators.buildEffective(knobs, flags, independent.workingDirectory)
			if evaluateCycleGuard, plan.resolvedCommand != independent.command {
				observe(.cycleGuardDiverged); throw errors.cycleGuardDiverged()
			}
			return .init(plan: plan, runtimeResolution: independent.runtimeResolution, launchProfileKey: independent.launchProfileKey,
				prelaunchEvaluation: evaluation, cycleGuard: evaluateCycleGuard ? .matched : .notEvaluatedObserveOnly, effectiveKnobs: knobs)
		}
	}
	private static func query(_ resolution: ClaudeRuntimeResolution, _ key: ClaudeLaunchProfileKey) -> ClaudePrelaunchQuery {
		switch resolution { case .resolved(let identity): return .resolved(identity: identity, launchProfileKey: key); case .unresolvable(let reason): return .unresolvable(reason) }
	}
	private static func effective(_ evaluation: ClaudeAdmissionEvaluation, _ requested: ClaudeLaunchEffectiveKnobs<Effort>) -> ClaudeLaunchEffectiveKnobs<Effort> {
		.derive(from: evaluation.decision, requestedSessionID: requested.existingSessionID, requestedModel: requested.model,
			requestedEffort: requested.effortLevel, requestedPermissionMode: requested.permissionMode)
	}
}
