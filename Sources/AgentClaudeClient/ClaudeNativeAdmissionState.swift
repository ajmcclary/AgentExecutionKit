import Foundation
import ClaudeRuntimeKit
import AgentClaudeLaunch
import AgentClaudeCapabilities
import AgentClaudeCompatibilityStorage

/// Immutable phase-A envelope. Execution and admission share the same plan;
/// the coordinator, enforcement stage and host provenance are carried into phase B.
public struct ClaudeAdmittedLaunch<Context: Sendable, Effort: RawRepresentable & Equatable & Sendable, Source: Equatable & Sendable>: Sendable where Effort.RawValue == String {
    public typealias CycleGuardState = ClaudeLaunchCycleGuardState
    public let plan: ClaudeNativeLaunchPlan<Context>
    public let runtimeResolution: ClaudeRuntimeResolution
    public let launchProfileKey: ClaudeLaunchProfileKey
    public let prelaunchEvaluation: ClaudeAdmissionEvaluation
    public let cycleGuard: CycleGuardState
    public let manifestSource: Source
    public let coordinator: ClaudeAdmissionCoordinator
    public let stage: ClaudeAdmissionEnforcementStage
    public let effectiveKnobs: ClaudeLaunchEffectiveKnobs<Effort>
    public init(plan: ClaudeNativeLaunchPlan<Context>, runtimeResolution: ClaudeRuntimeResolution, launchProfileKey: ClaudeLaunchProfileKey,
                prelaunchEvaluation: ClaudeAdmissionEvaluation, cycleGuard: CycleGuardState, manifestSource: Source,
                coordinator: ClaudeAdmissionCoordinator, stage: ClaudeAdmissionEnforcementStage, effectiveKnobs: ClaudeLaunchEffectiveKnobs<Effort>) {
        self.plan = plan; self.runtimeResolution = runtimeResolution; self.launchProfileKey = launchProfileKey
        self.prelaunchEvaluation = prelaunchEvaluation; self.cycleGuard = cycleGuard; self.manifestSource = manifestSource
        self.coordinator = coordinator; self.stage = stage; self.effectiveKnobs = effectiveKnobs
    }
}

public struct ClaudeFinalAdmission<Source: Equatable & Sendable>: Equatable, Sendable {
    public let validation: ClaudeBehavioralValidationOutcome
    public let permissionModeRoundTrip: ClaudePermissionModeRoundTrip
    public let initializeViolations: [ClaudeInitializeResponseWellFormedness.Violation]
    public let evaluation: ClaudeAdmissionEvaluation
    public let stage: ClaudeAdmissionEnforcementStage
    public let manifestSource: Source
    public let launchProfileKey: ClaudeLaunchProfileKey
    public let runtimeResolution: ClaudeRuntimeResolution
    public init(validation: ClaudeBehavioralValidationOutcome, permissionModeRoundTrip: ClaudePermissionModeRoundTrip,
                initializeViolations: [ClaudeInitializeResponseWellFormedness.Violation], evaluation: ClaudeAdmissionEvaluation,
                stage: ClaudeAdmissionEnforcementStage, manifestSource: Source, launchProfileKey: ClaudeLaunchProfileKey,
                runtimeResolution: ClaudeRuntimeResolution) {
        self.validation = validation; self.permissionModeRoundTrip = permissionModeRoundTrip; self.initializeViolations = initializeViolations
        self.evaluation = evaluation; self.stage = stage; self.manifestSource = manifestSource
        self.launchProfileKey = launchProfileKey; self.runtimeResolution = runtimeResolution
    }
}

/// Caller-actor-owned admission state. History observes decisions; it never feeds
/// classification. No identity, manifest, credential or catalog is read implicitly.
/// Reset starts a new epoch; diagnostic history remains available until adoption.
public final class ClaudeNativeAdmissionState<Context: Sendable, Effort: RawRepresentable & Equatable & Sendable, Source: Equatable & Sendable> where Effort.RawValue == String {
    public typealias Launch = ClaudeAdmittedLaunch<Context, Effort, Source>
    public typealias Final = ClaudeFinalAdmission<Source>
    public private(set) var admittedLaunch: Launch?
    public private(set) var finalAdmission: Final?
    public private(set) var capabilityProjection: ClaudeSessionCapabilityProjection<Effort>?
    public private(set) var compatibilityLookup: ClaudeCompatibilityCacheLookup?
    public private(set) var recordAgreement: ClaudeCompatibilityRecordAgreement?
    public enum Observation {
        case compatibilityLookup(ClaudeCompatibilityCacheLookup)
        case recordDiverged(ClaudeCompatibilityRecordAgreement, ClaudeCachedClassification, ClaudeCachedValidation)
        case postInitializeRejected(Final, ClaudeAdmissionRejectReason)
        case capabilityObserved(String, ClaudeAdmissionEnforcementStage)
        case capabilityRefused(String, ClaudeAdmissionEnforcementStage)
    }
    public init() {}
    public func resetEpoch() { admittedLaunch = nil; finalAdmission = nil; capabilityProjection = nil }
    @_spi(Testing) public func clearAdmittedLaunchForTesting() { admittedLaunch = nil }

    public func adopt(_ launch: Launch?, cache: ClaudeCompatibilityCache, observe: (Observation) -> Void) {
        admittedLaunch = launch
        guard let launch, case .resolved(let identity) = launch.runtimeResolution else { compatibilityLookup = nil; return }
        compatibilityLookup = cache.lookup(sha256: identity.sha256, launchProfileKey: launch.launchProfileKey)
        if let compatibilityLookup { observe(.compatibilityLookup(compatibilityLookup)) }
    }

    public func settle(initializeResult: [String: Any], permissionModeRoundTrip: ClaudePermissionModeRoundTrip,
                       staticModelCatalog: [String], staticEffortCatalog: [Effort], parseEffort: (String) -> Effort?,
                       cache: ClaudeCompatibilityCache, observe: (Observation) -> Void) throws {
        guard let admitted = admittedLaunch else { throw ClaudeNativeClientError.admissionEnvelopeMissing }
        let violations = ClaudeInitializeResponseWellFormedness.violations(of: initializeResult)
        let validation = ClaudeBehavioralValidator.validate(initializeResponseWellFormed: violations.isEmpty,
            permissionModeRoundTripSucceeded: permissionModeRoundTrip.satisfiesValidation)
        let query: ClaudePostInitializeQuery
        switch admitted.runtimeResolution {
        case .resolved(let identity): query = .resolved(identity: identity, launchProfileKey: admitted.launchProfileKey, validation: validation)
        case .unresolvable(let reason): query = .unresolvable(reason)
        }
        let evaluation = admitted.coordinator.evaluatePostInitialize(query, stage: admitted.stage)
        let final = Final(validation: validation, permissionModeRoundTrip: permissionModeRoundTrip, initializeViolations: violations,
            evaluation: evaluation, stage: admitted.stage, manifestSource: admitted.manifestSource,
            launchProfileKey: admitted.launchProfileKey, runtimeResolution: admitted.runtimeResolution)
        // Rejected outcomes must reach history too. History is written AFTER the
        // decision, before rejection, and is never read back as admission authority.
        recordCompatibilityOutcome(admitted, evaluation: evaluation, validation: validation, cache: cache, observe: observe)
        if case .reject(let reason) = evaluation.decision {
            observe(.postInitializeRejected(final, reason))
            throw ClaudeNativeClientError.admissionRejectedPostInitialize(reason)
        }
        finalAdmission = final
        capabilityProjection = ClaudeSessionCapabilityProjection.project(evaluation: evaluation,
            sessionModel: admitted.effectiveKnobs.model, sessionEffortLevel: admitted.effectiveKnobs.effortLevel,
            staticModelCatalog: staticModelCatalog, staticEffortCatalog: staticEffortCatalog,
            modelsValue: initializeResult["models"], fastModeStateValue: initializeResult["fast_mode_state"], parseEffort: parseEffort)
    }

    private func recordCompatibilityOutcome(_ admitted: Launch, evaluation: ClaudeAdmissionEvaluation,
            validation: ClaudeBehavioralValidationOutcome, cache: ClaudeCompatibilityCache, observe: (Observation) -> Void) {
        guard case .resolved(let identity) = admitted.runtimeResolution else { return }
        guard let classification = ClaudeCachedClassification(rawValue: evaluation.assessment.classification.durableCacheToken),
              let cachedValidation = ClaudeCachedValidation(rawValue: validation.durableCacheToken) else { return }
        let agreement = ClaudeCompatibilityRecordAgreement.between(prior: compatibilityLookup?.record,
            classification: classification, validation: cachedValidation)
        if agreement.isDivergent { observe(.recordDiverged(agreement, classification, cachedValidation)) }
        recordAgreement = agreement
        cache.store(sha256: identity.sha256, launchProfileKey: admitted.launchProfileKey, classification: classification, validation: cachedValidation)
    }

    public func effectivePermissionMode() throws -> String {
        guard let admittedLaunch else { throw ClaudeNativeClientError.admissionEnvelopeMissing }
        return admittedLaunch.effectiveKnobs.permissionMode
    }
    public func admitLiveSettings(model: String?, effortLevel: Effort?, fallbackStage: () -> ClaudeAdmissionEnforcementStage,
                                  observe: (Observation) -> Void) throws {
        guard let projection = capabilityProjection else { return }
        let stage = finalAdmission?.stage ?? fallbackStage()
        switch projection.admits(model: model, effortLevel: effortLevel, stage: stage) {
        case .allowed: break
        case .allowedObservedOnly(let reason): observe(.capabilityObserved("\(reason)", stage))
        case .refused(let reason):
            observe(.capabilityRefused("\(reason)", stage))
            throw ClaudeNativeClientError.capabilityNotOffered("\(reason)")
        }
    }
}
