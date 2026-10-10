import XCTest
import AgentClaudeLaunch
import ClaudeRuntimeKit

// Item 7, phase A: the launch gate turns the coordinator's prelaunch decision into
// a single launch action. The load-bearing property (Gate-2 lane-1 / review #4):
// a rejection short-circuits with NO cycle-guard second resolution; only an
// admitted stage-≥1 outcome requests it; stage 0 never does.

final class ClaudeAdmissionLaunchGateTests: XCTestCase {

	private let cli = ClaudeCliVersion.parse("2.1.215")!
	private lazy var behaviorKey = ClaudeBehaviorKey(input: ClaudeBehaviorKeyInput(
		cliVersion: cli, helpFlagSet: ["--print"], observedCapabilities: ["interrupt_receipt_v1"]))
	private lazy var launchProfileKey = ClaudeLaunchProfileKey(input: ClaudeLaunchProfileKeyInput(
		commandNameClass: .explicitPath, resumeRequested: false, modelRoute: .defaultRoute,
		effortClass: .defaultEffort, permissionModeClass: .requireApproval,
		backendClass: .standardClaude, authenticationModeClass: .anthropicAPIKey,
		workingDirectoryClass: .disposableOutsideRepo, mcpConfigPresent: true, mcpStrictMode: true,
		disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: [])))
	private let certifiedSha = ClaudeSHA256(String(repeating: "b", count: 64))!

	private func identity(_ sha: ClaudeSHA256) -> ClaudeRuntimeIdentity {
		ClaudeRuntimeIdentity(resolvedPath: "/x/claude", realPath: "/x/claude", sha256: sha,
			sizeBytes: 1, signingClass: .appleDeveloperID, pathClass: .userLocal)!
	}

	private func certifiedManifest() -> ClaudeCompatibilityManifest {
		let caps = ClaudeFamilyCapabilities(
			models: [], effortLevels: [],
			structuredOutput: ClaudeCapabilityEvidence(state: .uncertified, evidence: ""),
			resume: ClaudeCapabilityEvidence(state: .uncertified, evidence: ""),
			interrupt: ClaudeInterruptCapability(state: .certified, method: .inFlightCanary,
				abortSignals: [.assistantAborted, .resultTerminalReasonAbortedStreaming], evidence: "c"),
			permissionModeRoundTrip: true)
		let family = ClaudeManifestFamily(
			behaviorKey: behaviorKey,
			cliVersionRange: ClaudeCliVersionRange(min: cli, max: cli),
			certifiedIdentities: [ClaudeCertifiedIdentity(
				sha256: certifiedSha, launchProfileKey: launchProfileKey, signingClass: .appleDeveloperID)],
			classification: .supported, capabilities: caps, limitations: [], evidence: ["e"])
		return ClaudeCompatibilityManifest(schemaVersion: 1, manifestVersion: "2026-07-21.1",
										   families: [family], knownBadRules: [])
	}

	private func gate(_ manifest: ClaudeCompatibilityManifest,
					  _ stage: ClaudeAdmissionEnforcementStage) -> ClaudeAdmissionLaunchGate {
		ClaudeAdmissionLaunchGate(coordinator: ClaudeAdmissionCoordinator(manifest: manifest), stage: stage)
	}

	private func query(_ sha: ClaudeSHA256) -> ClaudePrelaunchQuery {
		.resolved(identity: identity(sha), launchProfileKey: launchProfileKey)
	}

	func testStageZeroProceedsWithoutCycleGuard() {
		// Even an unbound identity: stage 0 admits unrestricted and never asks for the
		// second resolution — the spawn path stays single-resolution and byte-identical.
		let action = gate(certifiedManifest(), .observeOnly).decidePrelaunch(query(ClaudeSHA256(String(repeating: "f", count: 64))!))
		guard case .proceed(_, let evaluateCycleGuard) = action else { return XCTFail("stage 0 must proceed") }
		XCTAssertFalse(evaluateCycleGuard)
	}

	func testAdmittedStageOneRequestsCycleGuard() {
		// A bound, certified identity under enforcement admits and REQUESTS the cycle
		// guard's second resolution.
		let action = gate(certifiedManifest(), .enforceKnownBad).decidePrelaunch(query(certifiedSha))
		guard case .proceed(let evaluation, let evaluateCycleGuard) = action else {
			return XCTFail("admitted identity must proceed")
		}
		XCTAssertTrue(evaluateCycleGuard)
		XCTAssertEqual(evaluation.assessment.classification, .fullyCertified)
	}

	func testRejectionShortCircuitsBeforeCycleGuard() {
		// An unbound identity under enforcement rejects — and the action is `.reject`,
		// so the controller never reaches the second resolution (review #4).
		let unbound = ClaudeSHA256(String(repeating: "f", count: 64))!
		let action = gate(certifiedManifest(), .enforceKnownBad).decidePrelaunch(query(unbound))
		guard case .reject(let reason, let evaluation) = action else {
			return XCTFail("unbound identity must reject under enforcement")
		}
		XCTAssertEqual(reason, .behaviorUnavailable)
		XCTAssertEqual(evaluation.assessment.classification, .behaviorUnavailable)
	}

	func testUnresolvableRejectsBeforeSpawnUnderEnforcement() {
		let action = gate(certifiedManifest(), .enforceKnownBad)
			.decidePrelaunch(.unresolvable(.noPath))
		guard case .reject(.unresolvableIdentity(.noPath), _) = action else {
			return XCTFail("unresolvable must reject")
		}
	}
}
