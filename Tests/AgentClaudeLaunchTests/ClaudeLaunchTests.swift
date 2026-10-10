import Foundation
import XCTest
import AgentClaudeLaunch
import AgentClaudeProtocol
import ClaudeRuntimeKit

private enum Effort: String, Sendable { case low, high, max }
private struct Provenance: Equatable, Sendable { let backend: String; let auth: String }
private struct Context: Sendable { let provenance: Provenance; let value: String }
private enum FixtureError: Error, Equatable { case flags, independent, rejected, drift, cycle }
private typealias Plan = ClaudeNativeLaunchPlan<Context>
private typealias Knobs = ClaudeLaunchEffectiveKnobs<Effort>
private typealias Flags = ClaudeLaunchFlagResolution<Context>
private typealias Service = ClaudeLaunchAdmissionService<Context, Effort, Provenance>

@MainActor
final class ClaudeLaunchTests: XCTestCase {
	private let context = Context(provenance: .init(backend: "backend", auth: "auth"), value: "evidence")
	private var key: ClaudeLaunchProfileKey { .init(input: .init(commandNameClass: .explicitPath, resumeRequested: false, modelRoute: .defaultRoute, effortClass: .defaultEffort, permissionModeClass: .requireApproval, backendClass: .standardClaude, authenticationModeClass: .anthropicAPIKey, workingDirectoryClass: .disposableOutsideRepo, mcpConfigPresent: true, mcpStrictMode: true, disallowedToolsDigest: .init(toolNames: []))) }
	private var identity: ClaudeRuntimeIdentity { .init(resolvedPath: "/x/claude", realPath: "/x/claude", sha256: .init(String(repeating: "b", count: 64))!, sizeBytes: 1, signingClass: .appleDeveloperID, pathClass: .userLocal)! }
	private var requested: Knobs { .init(existingSessionID: " raw-session ", model: "model", effortLevel: .high, permissionMode: "bypassPermissions") }
	private func manifest(limited: Bool = false) -> ClaudeCompatibilityManifest {
		let cli = ClaudeCliVersion.parse("2.1.215")!
		let caps = ClaudeFamilyCapabilities(models: ["model"], effortLevels: ["high"], structuredOutput: .init(state: .uncertified, evidence: ""), resume: .init(state: .uncertified, evidence: ""), interrupt: .init(state: .certified, method: .inFlightCanary, abortSignals: [.assistantAborted, .resultTerminalReasonAbortedStreaming], evidence: "c"), permissionModeRoundTrip: true)
		let family = ClaudeManifestFamily(behaviorKey: .init(input: .init(cliVersion: cli, helpFlagSet: ["--print"], observedCapabilities: ["interrupt_receipt_v1"])), cliVersionRange: .init(min: cli, max: cli), certifiedIdentities: [.init(sha256: identity.sha256, launchProfileKey: key, signingClass: .appleDeveloperID)], classification: limited ? .limited : .supported, capabilities: caps, limitations: [], evidence: ["e"])
		return .init(schemaVersion: 1, manifestVersion: "fixed", families: [family], knownBadRules: [])
	}
	private func plan(command: String = "/x/claude", directory: String = "/frozen", flags: ClaudeProtocolJSONObject? = nil) -> Plan {
		.init(resolvedCommand: command, arguments: ["-p", "--resume", " raw-session "], environment: ["EXACT": "v"], workingDirectory: directory, launchEnvironment: context, flagSettingsRequest: flags)
	}
	private func flags(_ context: Context? = nil) -> Flags { .init(launchEnvironment: context ?? self.context, environmentOverrides: ["MODEL": "x"], removedEnvironmentKeys: ["REMOVED"], request: nil) }
	private func service(calls: @escaping (String) -> Void = { _ in }, resolution: ClaudeRuntimeResolution? = nil,
		flagsFailure: Bool = false, independentFailure: Bool = false, requestedFailure: Bool = false,
		changed: Context? = nil, finalCommand: String = "/x/claude", inspect: ((Knobs, String) -> Void)? = nil) -> Service {
		Service(collaborators: .init(buildRequested: {
			calls("requested"); if requestedFailure { throw FixtureError.flags }; return self.plan()
		}, resolveIdentity: { _ in calls("identity"); return resolution ?? .resolved(self.identity) }, requestedProfile: { _ in calls("profile"); return self.key }, prepareIndependent: {
			calls("independent"); if independentFailure { throw FixtureError.independent }
			return .init(command: "/x/claude", runtimeResolution: resolution ?? .resolved(self.identity), launchProfileKey: self.key, workingDirectory: "/frozen", provenance: self.context.provenance)
		}, resolveEffectiveFlags: { knobs in
			calls("flags"); inspect?(knobs, "flags"); if flagsFailure { throw FixtureError.flags }; return self.flags(changed)
		}, provenance: { $0.provenance }, buildEffective: { knobs, _, directory in
			calls("effective"); inspect?(knobs, directory); return self.plan(command: finalCommand, directory: directory)
		}), errors: .init(rejected: { _ in FixtureError.rejected }, provenanceDrift: { FixtureError.drift }, cycleGuardDiverged: { FixtureError.cycle }))
	}
	func testObserveOnlyBuildsOnceThenIdentifiesAndDerivesRequestedProfile() async throws {
		var calls: [String] = []; let service = service(calls: { calls.append($0) }, resolution: .unresolvable(.noPath))
		let launch = try await service.resolve(stage: .observeOnly, coordinator: .init(manifest: .empty), requested: requested, observe: { _ in XCTFail("observe-only rejection event") })
		XCTAssertEqual(calls, ["requested", "identity", "profile"]); XCTAssertEqual(launch.effectiveKnobs, requested)
		XCTAssertEqual(launch.plan.arguments, ["-p", "--resume", " raw-session "]); XCTAssertEqual(launch.plan.environment, ["EXACT": "v"])
		XCTAssertEqual(launch.cycleGuard, .notEvaluatedObserveOnly); XCTAssertEqual(launch.runtimeResolution, .unresolvable(.noPath))
	}
	func testEnforcementUsesIndependentThenEffectiveInputsAndFrozenWorkingDirectory() async throws {
		var calls: [String] = []; var directories: [String] = []
		let service = service(calls: { calls.append($0) }, inspect: { _, directory in directories.append(directory) })
		let launch = try await service.resolve(stage: .enforceKnownBad, coordinator: .init(manifest: manifest()), requested: requested, observe: { _ in XCTFail("unexpected event") })
		XCTAssertEqual(calls, ["independent", "flags", "effective"]); XCTAssertEqual(directories, ["flags", "/frozen"])
		XCTAssertEqual(launch.launchProfileKey, key); XCTAssertEqual(launch.runtimeResolution, .resolved(identity)); XCTAssertEqual(launch.cycleGuard, .matched)
		XCTAssertEqual(launch.effectiveKnobs, requested)
	}
	func testEarlyRejectionNeverResolvesEffectiveFlagsOrBuildsFinalPlan() async {
		var calls: [String] = []; var rejected = 0
		do { _ = try await service(calls: { calls.append($0) }, resolution: .unresolvable(.noPath)).resolve(stage: .enforceKnownBad, coordinator: .init(manifest: .empty), requested: requested) { if case .rejected(.unresolvableIdentity(.noPath)) = $0 { rejected += 1 } }; XCTFail("expected reject") }
		catch { XCTAssertEqual(error as? FixtureError, .rejected) }
		XCTAssertEqual(calls, ["independent"]); XCTAssertEqual(rejected, 1)
	}
	func testBackendOrAuthenticationDriftFailsBeforeFinalPlanConstruction() async {
		for changed in [Provenance(backend: "other", auth: "auth"), Provenance(backend: "backend", auth: "other")] {
			var calls: [String] = []; var events = 0
			do { _ = try await service(calls: { calls.append($0) }, changed: .init(provenance: changed, value: "same")).resolve(stage: .enforceKnownBad, coordinator: .init(manifest: manifest()), requested: requested) { if case .provenanceDrift = $0 { events += 1 } }; XCTFail("expected drift") }
			catch { XCTAssertEqual(error as? FixtureError, .drift) }
			XCTAssertEqual(calls, ["independent", "flags"]); XCTAssertEqual(events, 1)
		}
	}
	func testCommandCycleDivergenceRejectsAfterFinalConstruction() async {
		var calls: [String] = []; var events = 0
		do { _ = try await service(calls: { calls.append($0) }, finalCommand: "/other/claude").resolve(stage: .enforceKnownBad, coordinator: .init(manifest: manifest()), requested: requested) { if case .cycleGuardDiverged = $0 { events += 1 } }; XCTFail("expected cycle divergence") }
		catch { XCTAssertEqual(error as? FixtureError, .cycle) }
		XCTAssertEqual(calls, ["independent", "flags", "effective"]); XCTAssertEqual(events, 1)
	}
	func testLimitedAdmissionPassesConservativeKnobsToFlagsAndPlan() async throws {
		var observed: [Knobs] = []
		let launch = try await service(inspect: { knobs, _ in observed.append(knobs) }).resolve(stage: .enforceLimited, coordinator: .init(manifest: manifest(limited: true)), requested: requested, observe: { _ in })
		XCTAssertEqual(observed.count, 2); XCTAssertTrue(observed.allSatisfy { $0.model == nil && $0.effortLevel == nil && $0.existingSessionID == nil && $0.permissionMode == "default" })
		XCTAssertEqual(launch.effectiveKnobs, observed.first)
	}
	func testFullAdmissionDropsUncertifiedResumeButRetainsCatalogMatchedKnobs() async throws {
		let launch = try await service().resolve(stage: .enforceAll, coordinator: .init(manifest: manifest()), requested: requested, observe: { _ in })
		XCTAssertNil(launch.effectiveKnobs.existingSessionID); XCTAssertEqual(launch.effectiveKnobs.model, "model")
		XCTAssertEqual(launch.effectiveKnobs.effortLevel, .high); XCTAssertEqual(launch.effectiveKnobs.permissionMode, "bypassPermissions")
	}
	func testFailureAtEachAsyncHostPortShortCircuitsFollowingWork() async {
		for mode in 0..<3 {
			var calls: [String] = []
			do { _ = try await service(calls: { calls.append($0) }, flagsFailure: mode == 2, independentFailure: mode == 1, requestedFailure: mode == 0).resolve(stage: mode == 0 ? .observeOnly : .enforceKnownBad, coordinator: .init(manifest: manifest()), requested: requested, observe: { _ in XCTFail("host error should propagate") }); XCTFail("expected host failure") }
			catch { XCTAssertTrue(error is FixtureError) }
			XCTAssertEqual(calls, mode == 0 ? ["requested"] : mode == 1 ? ["independent"] : ["independent", "flags"])
		}
	}
	func testObserveOnlyDoesNotApplyEnforcementProvenanceOrCommandGuard() async throws {
		let launch = try await service(changed: .init(provenance: .init(backend: "other", auth: "other"), value: "different"), finalCommand: "/other").resolve(stage: .observeOnly, coordinator: .init(manifest: manifest()), requested: requested, observe: { _ in XCTFail("no enforce events") })
		XCTAssertEqual(launch.plan.resolvedCommand, "/x/claude"); XCTAssertEqual(launch.effectiveKnobs, requested)
	}
	func testImmutableArtifactRetainsContextAndPrecisionWithoutFoundationReferenceSharing() throws {
		let json = try ClaudeProtocolJSONObject(object: ["future": NSNumber(value: Int64(9007199254740993))])
		let p = plan(flags: json); var first = try json.dictionary(); first["future"] = "changed"
		XCTAssertEqual((try p.flagSettingsRequest?.dictionary()["future"] as? NSNumber)?.int64Value, 9007199254740993)
		XCTAssertEqual(p.launchEnvironment.value, "evidence")
	}
	private func builder(_ record: @escaping (String) -> Void, flagsFailure: Bool = false, inspect: ((String?, Effort?) -> Void)? = nil, inspectEnvironment: (([String: String]) -> Void)? = nil, inspectSession: ((String?) -> Void)? = nil) -> ClaudeNativeLaunchPlanBuilder<Context, Effort> {
		.init(collaborators: .init(resolveFlagSettings: { model, effort in
			record("flags"); inspect?(model, effort); if flagsFailure { throw FixtureError.flags }; return self.flags()
		}, composeEnvironment: { overrides, removed in record("environment"); XCTAssertEqual(overrides, ["MODEL": "x"]); XCTAssertEqual(removed, ["REMOVED"]); return ["COMPOSED": "yes"] }, resolveCommand: { environment in record("command"); inspectEnvironment?(environment); return "/x/claude" }, buildArguments: { id in record("args"); inspectSession?(id); return ["-p"] }, workingDirectory: { record("directory"); return "/frozen" }))
	}
	func testBuilderRunsAllCollaboratorsInExactOrder() async throws {
		var calls: [String] = []; _ = try await builder({ calls.append($0) }).build(existingSessionID: nil, model: nil, effortLevel: nil)
		XCTAssertEqual(calls, ["flags", "environment", "command", "args", "directory"])
	}
	func testBuilderResolvesOnceForEachIndependentPlan() async throws {
		var calls: [String] = []; let b = builder({ calls.append($0) })
		for _ in 0..<2 { _ = try await b.build(existingSessionID: nil, model: nil, effortLevel: nil) }
		for name in ["flags", "environment", "command", "args", "directory"] { XCTAssertEqual(calls.filter { $0 == name }.count, 2) }
	}
	func testBuilderFailureStopsBeforeEnvironmentAndCommandWork() async {
		var calls: [String] = []
		do { _ = try await builder({ calls.append($0) }, flagsFailure: true).build(existingSessionID: nil, model: nil, effortLevel: nil); XCTFail("expected failure") } catch { XCTAssertEqual(error as? FixtureError, .flags) }
		XCTAssertEqual(calls, ["flags"])
	}
	func testBuilderUsesComposedEnvironmentAndRawSessionAndOnlyFlagsReceiveModelEffort() async throws {
		var environment: [String: String] = [:]; var id: String?; var model: String?; var effort: Effort?
		let p = try await builder({ _ in }, inspect: { model = $0; effort = $1 }, inspectEnvironment: { environment = $0 }, inspectSession: { id = $0 }).build(existingSessionID: " raw ", model: " m ", effortLevel: .max)
		XCTAssertEqual(environment, ["COMPOSED": "yes"]); XCTAssertEqual(p.environment, environment)
		XCTAssertEqual(id, " raw "); XCTAssertEqual(model, " m "); XCTAssertEqual(effort, .max)
	}
	func testUnrestrictedKnobsPreserveRawInputsIncludingEmptyAndWhitespace() {
		for mode in ["bypassPermissions", "BYPASSPERMISSIONS", " ", ""] {
			let value = Knobs.derive(from: .admitUnrestricted, requestedSessionID: " raw ", requestedModel: " m ", requestedEffort: .max, requestedPermissionMode: mode)
			XCTAssertEqual(value, .init(existingSessionID: " raw ", model: " m ", effortLevel: .max, permissionMode: mode))
		}
	}
	func testFullKnobsUseExactCaseSensitiveCatalogMembership() {
		let offered = ClaudeOfferedCapabilities(models: ["model"], effortLevels: ["high"], structuredOutput: false, resume: true, permissionModeRoundTrip: true)
		let matched = Knobs.derive(from: .admitFull(offered), requestedSessionID: "s", requestedModel: "model", requestedEffort: .high, requestedPermissionMode: "bypassPermissions")
		XCTAssertEqual(matched, .init(existingSessionID: "s", model: "model", effortLevel: .high, permissionMode: "bypassPermissions"))
		for model in ["MODEL", " model ", "", "unknown"] {
			let miss = Knobs.derive(from: .admitFull(offered), requestedSessionID: "s", requestedModel: model, requestedEffort: .max, requestedPermissionMode: "default")
			XCTAssertNil(miss.model); XCTAssertNil(miss.effortLevel)
		}
	}
	func testRejectKnobsFailClosedAndPreserveNonBypassModes() {
		for mode in ["default", "acceptEdits", " bypassPermissions ", ""] {
			let value = Knobs.derive(from: .reject(.behaviorUnavailable), requestedSessionID: "s", requestedModel: "m", requestedEffort: .high, requestedPermissionMode: mode)
			XCTAssertEqual(value, .init(existingSessionID: nil, model: nil, effortLevel: nil, permissionMode: mode))
		}
		let value = Knobs.derive(from: .reject(.behaviorUnavailable), requestedSessionID: "s", requestedModel: "m", requestedEffort: .high, requestedPermissionMode: "BYPASSPERMISSIONS")
		XCTAssertEqual(value.permissionMode, "default")
	}
	func testCycleGuardVocabularyIsClosed() { XCTAssertNotEqual(ClaudeLaunchCycleGuardState.matched, .notEvaluatedObserveOnly) }
}
