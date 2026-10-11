import XCTest
import Synchronization
@_spi(Testing) import AgentClaudeClient
import AgentClaudeLaunch
import AgentClaudeCapabilities
import AgentClaudeCompatibilityStorage
import AIClientStorage
import ClaudeRuntimeKit

final class ClaudeNativeAdmissionStateTests: XCTestCase {
    private enum Effort: String, Sendable { case high, low }
    private typealias Owner = ClaudeNativeAdmissionState<String, Effort, String>
    private final class Preferences: AIDataPreferences {
        private let values = Mutex<[String: Data]>([:])
        func data(forKey key: String) -> Data? { values.withLock { $0[key] } }
        func set(_ data: Data, forKey key: String) { values.withLock { $0[key] = data } }
        func remove(forKey key: String) { _ = values.withLock { $0.removeValue(forKey: key) } }
        var snapshot: [String: Data] { values.withLock { $0 } }
    }
    private let sha = ClaudeSHA256(String(repeating: "b", count: 64))!
    private var key: ClaudeLaunchProfileKey {
        .init(input: .init(commandNameClass: .explicitPath, resumeRequested: false, modelRoute: .defaultRoute,
            effortClass: .defaultEffort, permissionModeClass: .requireApproval, backendClass: .standardClaude,
            authenticationModeClass: .anthropicAPIKey, workingDirectoryClass: .disposableOutsideRepo,
            mcpConfigPresent: true, mcpStrictMode: true, disallowedToolsDigest: .init(toolNames: [])))
    }
    private var identity: ClaudeRuntimeIdentity {
        .init(resolvedPath: "/host/claude", realPath: "/host/claude", sha256: sha, sizeBytes: 1,
            signingClass: .appleDeveloperID, pathClass: .userLocal)!
    }
    private func cache(_ preferences: Preferences, namespace: String = "host") -> ClaudeCompatibilityCache {
        .init(preferences: preferences, namespace: namespace, environment: .init(manifestVersion: "manifest", appBuild: "host-build", probeSchemaVersion: 1))
    }
    private func launch(stage: ClaudeAdmissionEnforcementStage = .enforceAll, unresolved: Bool = false,
                        certified: Bool = true, source: String = "host-source", mode: String = "acceptEdits") -> Owner.Launch {
        let cli = ClaudeCliVersion.parse("2.1.215")!
        let caps = ClaudeFamilyCapabilities(models: ["opus", "sonnet"], effortLevels: ["high"],
            structuredOutput: .init(state: .uncertified, evidence: ""), resume: .init(state: .uncertified, evidence: ""),
            interrupt: .init(state: .certified, method: .inFlightCanary, abortSignals: [.assistantAborted], evidence: "fixture"), permissionModeRoundTrip: true)
        let family = ClaudeManifestFamily(behaviorKey: .init(input: .init(cliVersion: cli, helpFlagSet: ["--print"], observedCapabilities: ["interrupt_receipt_v1"])),
            cliVersionRange: .init(min: cli, max: cli), certifiedIdentities: [.init(sha256: sha, launchProfileKey: key, signingClass: .appleDeveloperID)],
            classification: .supported, capabilities: caps, limitations: [], evidence: ["fixture"])
        let manifest = certified ? ClaudeCompatibilityManifest(schemaVersion: 1, manifestVersion: "manifest", families: [family], knownBadRules: []) : .empty
        let coordinator = ClaudeAdmissionCoordinator(manifest: manifest)
        let resolution: ClaudeRuntimeResolution = unresolved ? .unresolvable(.missingPath) : .resolved(identity)
        let query: ClaudePrelaunchQuery = unresolved ? .unresolvable(.missingPath) : .resolved(identity: identity, launchProfileKey: key)
        return .init(plan: .init(resolvedCommand: "/host/claude", arguments: ["-p"], environment: ["HOST": "value"], workingDirectory: "/host/root",
                    launchEnvironment: "host-context", flagSettingsRequest: nil), runtimeResolution: resolution, launchProfileKey: key,
            prelaunchEvaluation: coordinator.evaluatePrelaunch(query, stage: stage), cycleGuard: .matched,
            manifestSource: source, coordinator: coordinator, stage: stage,
            effectiveKnobs: .init(existingSessionID: "host-session", model: "opus", effortLevel: .high, permissionMode: mode))
    }
    private var response: [String: Any] {
        ["commands": [["name": "compact"]], "output_style": "default", "available_output_styles": ["default"], "pid": 4242, "models": ["opus", "future"]]
    }
    private func settle(_ owner: Owner, cache: ClaudeCompatibilityCache, response: [String: Any]? = nil,
                        permission: ClaudePermissionModeRoundTrip = .confirmed(mode: "acceptEdits"), observe: (Owner.Observation) -> Void = { _ in }) throws {
        try owner.settle(initializeResult: response ?? self.response, permissionModeRoundTrip: permission,
            staticModelCatalog: ["opus", "sonnet"], staticEffortCatalog: [.high, .low], parseEffort: { Effort(rawValue: $0) }, cache: cache, observe: observe)
    }
    func testMissingEnvelopeFailsClosedBeforeHistoryOrProjection() {
        let owner = Owner(); let preferences = Preferences(); let cache = cache(preferences)
        XCTAssertThrowsError(try settle(owner, cache: cache)) { XCTAssertEqual($0 as? ClaudeNativeClientError, .admissionEnvelopeMissing) }
        XCTAssertThrowsError(try owner.effectivePermissionMode()) { XCTAssertEqual($0 as? ClaudeNativeClientError, .admissionEnvelopeMissing) }
        XCTAssertNil(owner.finalAdmission); XCTAssertNil(owner.capabilityProjection); XCTAssertTrue(preferences.snapshot.isEmpty)
    }
    func testSettlementCarriesIdentityStageSourceEffectiveKnobsAndSameInitializeSnapshot() throws {
        let owner = Owner(); let cache = cache(Preferences()); let launch = launch()
        owner.adopt(launch, cache: cache, observe: { _ in })
        try settle(owner, cache: cache)
        let final = try XCTUnwrap(owner.finalAdmission); let projection = try XCTUnwrap(owner.capabilityProjection)
        XCTAssertEqual(final.stage, launch.stage); XCTAssertEqual(final.manifestSource, launch.manifestSource)
        XCTAssertEqual(final.launchProfileKey, launch.launchProfileKey); XCTAssertEqual(final.runtimeResolution, launch.runtimeResolution)
        XCTAssertTrue(final.initializeViolations.isEmpty); XCTAssertEqual(final.permissionModeRoundTrip, .confirmed(mode: "acceptEdits"))
        XCTAssertEqual(projection.sessionModel, "opus"); XCTAssertEqual(projection.sessionEffortLevel, .high)
        XCTAssertEqual(projection.dynamic.effectiveModels, ["opus"]); XCTAssertEqual(projection.dynamic.effectiveEffortLevels, [.high])
        XCTAssertFalse(projection.offersResume); XCTAssertFalse(projection.offersStructuredOutput)
        XCTAssertEqual(try owner.effectivePermissionMode(), "acceptEdits")
    }
    func testHistoryWritesRejectedOutcomeBeforeReportingRejectionAndNeverGrantsFromAPriorSuccess() throws {
        let owner = Owner(); let cache = cache(Preferences()); let launch = launch()
        owner.adopt(launch, cache: cache, observe: { _ in }); try settle(owner, cache: cache)
        owner.resetEpoch(); owner.adopt(launch, cache: cache, observe: { _ in })
        XCTAssertEqual(owner.compatibilityLookup?.record?.validation, .observedPassed)
        var order: [String] = []
        XCTAssertThrowsError(try settle(owner, cache: cache, permission: .modeMismatch(requested: "acceptEdits", returned: "default"), observe: { event in
            switch event {
            case .recordDiverged(let agreement, _, let validation):
                XCTAssertTrue(agreement.isDivergent); XCTAssertEqual(validation, .observedFailed)
                XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key).record?.validation, .observedPassed)
                order.append("divergence")
            case .postInitializeRejected:
                XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key).record?.validation, .observedFailed)
                XCTAssertNil(owner.finalAdmission); XCTAssertNil(owner.capabilityProjection); order.append("rejection")
            default: XCTFail()
            }
        })) { error in
            guard case .admissionRejectedPostInitialize = error as? ClaudeNativeClientError else { return XCTFail("wrong error: \(error)") }
            order.append("throw")
        }
        XCTAssertEqual(order, ["divergence", "rejection", "throw"]); XCTAssertTrue(owner.recordAgreement?.isDivergent == true)
    }
    func testUnknownHistoryDoesNotCertifyRuntimeAtObserveOnly() throws {
        let owner = Owner(); let cache = cache(Preferences())
        cache.store(sha256: sha, launchProfileKey: key, classification: .exactCertified, validation: .observedPassed)
        owner.adopt(launch(stage: .observeOnly, certified: false), cache: cache, observe: { _ in })
        try settle(owner, cache: cache)
        XCTAssertEqual(cache.lookup(sha256: sha, launchProfileKey: key).record?.classification, .noExactMatch)
        XCTAssertEqual(owner.finalAdmission?.evaluation.assessment.classification, .behaviorUnavailable)
    }
    func testUnresolvableIdentityDoesNotInventHistoryIdentityOrLookup() throws {
        let owner = Owner(); let preferences = Preferences(); let cache = cache(preferences)
        owner.adopt(launch(stage: .observeOnly, unresolved: true), cache: cache, observe: { _ in XCTFail() })
        try settle(owner, cache: cache)
        XCTAssertNil(owner.compatibilityLookup); XCTAssertNil(owner.recordAgreement); XCTAssertTrue(preferences.snapshot.isEmpty)
        XCTAssertEqual(owner.finalAdmission?.runtimeResolution, .unresolvable(.missingPath))
    }
    func testEpochResetRetiresAllAdmissionSnapshotsButKeepsDiagnosticHistoryUntilAdoption() throws {
        let owner = Owner(); let cache = cache(Preferences())
        owner.adopt(launch(), cache: cache, observe: { _ in }); try settle(owner, cache: cache)
        let lookup = owner.compatibilityLookup; let agreement = owner.recordAgreement
        owner.resetEpoch()
        XCTAssertNil(owner.admittedLaunch); XCTAssertNil(owner.finalAdmission); XCTAssertNil(owner.capabilityProjection)
        XCTAssertEqual(owner.compatibilityLookup, lookup); XCTAssertEqual(owner.recordAgreement, agreement)
        owner.adopt(nil, cache: cache, observe: { _ in XCTFail() })
        XCTAssertNil(owner.compatibilityLookup); XCTAssertEqual(owner.recordAgreement, agreement)
    }
    func testAdoptionLooksUpTheExactCarriedIdentityAndProfile() {
        let owner = Owner(); let cache = cache(Preferences())
        cache.store(sha256: sha, launchProfileKey: key, classification: .exactCertified, validation: .observedPassed)
        var observations = 0
        owner.adopt(launch(), cache: cache, observe: { if case .compatibilityLookup(let lookup) = $0 { XCTAssertNotNil(lookup.record); observations += 1 } else { XCTFail() } })
        XCTAssertEqual(observations, 1); XCTAssertEqual(owner.compatibilityLookup?.record?.decodedIdentity?.sha256, sha)
    }
    func testLiveRefusalsAtStageTwoAndThreePreventFollowingSettingsEffects() throws {
        for stage in [ClaudeAdmissionEnforcementStage.enforceLimited, .enforceAll] {
            let owner = Owner(); let cache = cache(Preferences()); owner.adopt(launch(stage: stage), cache: cache, observe: { _ in }); try settle(owner, cache: cache)
            var effects = 0; var refusals = 0
            do {
                try owner.admitLiveSettings(model: "future", effortLevel: nil, fallbackStage: { XCTFail(); return .observeOnly }, observe: {
                    if case .capabilityRefused(_, let recordedStage) = $0 { XCTAssertEqual(recordedStage, stage); refusals += 1 } else { XCTFail() }
                }); effects += 1; XCTFail()
            } catch { XCTAssertTrue((error as? ClaudeNativeClientError)?.isCapabilityRefusal == true) }
            XCTAssertEqual(effects, 0); XCTAssertEqual(refusals, 1)
        }
    }
    func testStageZeroAndOneObserveLiveRefusalsWithoutChangingRequests() throws {
        for stage in [ClaudeAdmissionEnforcementStage.observeOnly, .enforceKnownBad] {
            let owner = Owner(); let cache = cache(Preferences()); owner.adopt(launch(stage: stage), cache: cache, observe: { _ in }); try settle(owner, cache: cache)
            var observed = 0
            try owner.admitLiveSettings(model: "future", effortLevel: .low, fallbackStage: { XCTFail(); return .enforceAll }, observe: {
                if case .capabilityObserved(_, let recordedStage) = $0 { XCTAssertEqual(recordedStage, stage); observed += 1 } else { XCTFail() }
            })
            XCTAssertEqual(observed, 1)
        }
    }
    func testAllowedLiveSettingsAndUnsettledEpochDoNotReadFallbackOrInventObservations() throws {
        let owner = Owner(); let cache = cache(Preferences())
        try owner.admitLiveSettings(model: "future", effortLevel: .low, fallbackStage: { XCTFail(); return .enforceAll }, observe: { _ in XCTFail() })
        owner.adopt(launch(), cache: cache, observe: { _ in }); try settle(owner, cache: cache)
        try owner.admitLiveSettings(model: "opus:high", effortLevel: .high, fallbackStage: { XCTFail(); return .observeOnly }, observe: { _ in XCTFail() })
    }
    func testHostNamespacesAndDynamicSessionStateStaySeparate() throws {
        let preferences = Preferences(); let first = cache(preferences, namespace: "first"); let second = cache(preferences, namespace: "second")
        let a = Owner(); let b = Owner()
        a.adopt(launch(source: "first"), cache: first, observe: { _ in }); try settle(a, cache: first)
        b.adopt(launch(source: "second"), cache: second, observe: { _ in }); try settle(b, cache: second, response: response.merging(["models": ["sonnet"]], uniquingKeysWith: { _, rhs in rhs }))
        XCTAssertEqual(a.capabilityProjection?.dynamic.effectiveModels, ["opus"]); XCTAssertEqual(b.capabilityProjection?.dynamic.effectiveModels, ["sonnet"])
        a.resetEpoch(); XCTAssertNotNil(b.capabilityProjection); XCTAssertEqual(b.finalAdmission?.manifestSource, "second")
        XCTAssertEqual(Set(preferences.snapshot.keys), ["first", "second"])
        for data in preferences.snapshot.values {
            let encoded = String(decoding: data, as: UTF8.self)
            for forbidden in ["opus", "sonnet", "host-context", "host-session", "fast_mode_state"] { XCTAssertFalse(encoded.contains(forbidden)) }
        }
        first.removeAll(); XCTAssertNil(preferences.snapshot["first"]); XCTAssertNotNil(preferences.snapshot["second"])
    }
    func testValidationKeepsFoundationValueSemanticsAndNeedsNoSessionIDOrSystemInit() throws {
        for pid: Any in [1, 4242, true, "4242"] {
            let owner = Owner(); let cache = cache(Preferences()); owner.adopt(launch(stage: .observeOnly), cache: cache, observe: { _ in })
            let input = response.merging(["pid": pid], uniquingKeysWith: { _, rhs in rhs })
            try settle(owner, cache: cache, response: input)
            XCTAssertEqual(owner.finalAdmission?.initializeViolations, ClaudeInitializeResponseWellFormedness.violations(of: input))
            XCTAssertNil(input["session_id"]); XCTAssertNil(input["capabilities"])
        }
    }
}
