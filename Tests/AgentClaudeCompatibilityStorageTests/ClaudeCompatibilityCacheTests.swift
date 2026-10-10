import XCTest
@testable import AgentClaudeCompatibilityStorage
import ClaudeRuntimeKit
import AIClientStorage

/// Item 11 — the durable exact-identity compatibility cache (§1.3).
///
/// The five invalidation axes get ONE TEST EACH, deliberately. A single combined
/// test ("change everything, expect a miss") passes with four of the five checks
/// deleted, which is precisely the bug it would be written to catch. Each test below
/// varies exactly one axis and asserts the SPECIFIC miss reason, so a deleted check
/// fails one named test rather than none.
///
/// The other half of this suite is about what the cache must never become. A cache
/// that can upgrade an unknown binary, resurrect a known-bad identity, or outlive a
/// dynamic capability is not a performance optimisation — it is a second, stale
/// admission authority.
final class ClaudeCompatibilityCacheTests: XCTestCase {

	private var defaults: UserDefaults!
	private var suiteName: String!

	private let sha = ClaudeSHA256(String(repeating: "a", count: 64))!
	private let otherSHA = ClaudeSHA256(String(repeating: "b", count: 64))!
	private let key = CacheTestKeys.key(seed: 1)
	private let otherKey = CacheTestKeys.key(seed: 2)

	private func environment(
		manifestVersion: String = "2026-07-21.1",
		appBuild: String = "build-100",
		probeSchemaVersion: Int = ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion
	) -> ClaudeCompatibilityCacheEnvironment {
		ClaudeCompatibilityCacheEnvironment(
			manifestVersion: manifestVersion, appBuild: appBuild,
			probeSchemaVersion: probeSchemaVersion)
	}

	private func cache(_ environment: ClaudeCompatibilityCacheEnvironment? = nil) -> ClaudeCompatibilityCache {
		ClaudeCompatibilityCache(preferences: AIDefaultsDataPreferences(defaults: defaults), namespace: "claude.compatibility.cache.v1", environment: environment ?? self.environment())
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "ClaudeCompatibilityCacheTests-\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
	}

	override func tearDownWithError() throws {
		defaults.removePersistentDomain(forName: suiteName)
		defaults = nil
		suiteName = nil
		try super.tearDownWithError()
	}

	/// Seeds one record under the baseline environment.
	@discardableResult
	private func seedBaseline(
		classification: ClaudeCachedClassification = .exactCertified,
		validation: ClaudeCachedValidation = .observedPassed
	) -> Bool {
		cache().store(sha256: sha, launchProfileKey: key,
					  classification: classification, validation: validation)
	}

	// MARK: - Exact hit

	func testExactIdentityAndEnvironmentProducesAHit() {
		XCTAssertTrue(seedBaseline())
		let lookup = cache().lookup(sha256: sha, launchProfileKey: key)
		let record = try? XCTUnwrap(lookup.record)
		XCTAssertEqual(record?.classification, .exactCertified)
		XCTAssertEqual(record?.validation, .observedPassed)
		XCTAssertEqual(record?.sha256, sha.value)
		XCTAssertEqual(record?.launchProfileKey, key.digest.value)
		// The typed round trip, not just the strings.
		XCTAssertEqual(record?.decodedIdentity?.sha256, sha)
		XCTAssertEqual(record?.decodedIdentity?.launchProfileDigest, key.digest)
	}

	func testAbsentRecordIsAPlainMiss() {
		XCTAssertEqual(cache().lookup(sha256: sha, launchProfileKey: key), .miss(.noRecord))
	}

	// MARK: - The five invalidation axes, ONE TEST EACH

	func testAxis1_BinarySHAChangeForcesAMiss() {
		seedBaseline()
		XCTAssertEqual(
			cache().lookup(sha256: otherSHA, launchProfileKey: key), .miss(.noRecord),
			"a different binary is a different cache key entirely — it must never read the old record"
		)
		// And the original identity still hits, so the miss is about the SHA, not about
		// the cache having been emptied.
		XCTAssertNotNil(cache().lookup(sha256: sha, launchProfileKey: key).record)
	}

	func testAxis2_LaunchProfileKeyChangeForcesAMiss() {
		seedBaseline()
		XCTAssertEqual(
			cache().lookup(sha256: sha, launchProfileKey: otherKey), .miss(.noRecord),
			"the same binary under a different launch profile is a different question"
		)
		XCTAssertNotNil(cache().lookup(sha256: sha, launchProfileKey: key).record)
	}

	func testAxis3_ManifestVersionChangeForcesAMiss() {
		seedBaseline()
		let newer = cache(environment(manifestVersion: "2026-08-01.1"))
		XCTAssertEqual(
			newer.lookup(sha256: sha, launchProfileKey: key), .miss(.manifestVersionChanged),
			"a new manifest may reclassify this identity; the old answer must not be served"
		)
	}

	func testAxis4_AppBuildChangeForcesAMiss() {
		seedBaseline()
		let rebuilt = cache(environment(appBuild: "build-101"))
		XCTAssertEqual(
			rebuilt.lookup(sha256: sha, launchProfileKey: key), .miss(.appBuildChanged),
			"the code that APPLIES the rules changed, so the cached conclusion is unproven"
		)
	}

	func testAxis5_ProbeSchemaVersionChangeForcesAMiss() {
		seedBaseline()
		let reshaped = cache(environment(probeSchemaVersion:
			ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion + 1))
		XCTAssertEqual(
			reshaped.lookup(sha256: sha, launchProfileKey: key), .miss(.probeSchemaVersionChanged),
			"the observation that produced the record changed shape"
		)
	}

	/// Non-vacuity for the three environment axes: with NOTHING varied, the same
	/// lookup hits. Without this, all three tests above would pass against a cache
	/// that never hits at all.
	func testTheEnvironmentAxisTestsAreNotPassingBecauseNothingEverHits() {
		seedBaseline()
		XCTAssertNotNil(cache(environment()).lookup(sha256: sha, launchProfileKey: key).record,
						"an unchanged environment MUST hit, or the axis tests prove nothing")
	}

	// MARK: - Corruption

	func testCorruptRecordIsAMissThenIsOverwrittenSafely() throws {
		seedBaseline()

		// Corrupt the stored bytes for this key while leaving the envelope intact.
		let raw = try XCTUnwrap(defaults.data(forKey: "claude.compatibility.cache.v1"))
		var envelope = try XCTUnwrap(
			JSONSerialization.jsonObject(with: raw) as? [String: Any])
		var entries = try XCTUnwrap(envelope["entries"] as? [String: Any])
		let storageKey = ClaudeCompatibilityCache.storageKey(sha256: sha, launchProfileKey: key)
		entries[storageKey] = Data("this is not a record".utf8).base64EncodedString()
		envelope["entries"] = entries
		defaults.set(try JSONSerialization.data(withJSONObject: envelope),
					 forKey: "claude.compatibility.cache.v1")

		XCTAssertEqual(cache().lookup(sha256: sha, launchProfileKey: key), .miss(.corruptRecord),
					   "corrupt bytes must read as a MISS, not as a decode crash or a stale hit")

		// Re-validate and overwrite — the §10.2 contract.
		XCTAssertTrue(cache().store(sha256: sha, launchProfileKey: key,
									classification: .exactLimited, validation: .observedFailed))
		let after = cache().lookup(sha256: sha, launchProfileKey: key)
		XCTAssertEqual(after.record?.classification, .exactLimited)
		XCTAssertEqual(after.record?.validation, .observedFailed)
	}

	// MARK: - What the cache may never hold or do

	/// An unknown binary caches AS unknown. It must never become known.
	func testUnknownIdentityStaysUnknownAndIsNeverUpgraded() {
		XCTAssertTrue(cache().store(sha256: sha, launchProfileKey: key,
									classification: .noExactMatch, validation: .observedPassed))
		let record = cache().lookup(sha256: sha, launchProfileKey: key).record
		XCTAssertEqual(record?.classification, .noExactMatch,
					   "a cached unknown identity must round-trip as unknown — never upgraded")
		XCTAssertNotEqual(record?.classification, .exactCertified)
	}

	/// An ambiguous or unresolvable identity is never stored and never served.
	func testAmbiguousAndUnresolvableIdentitiesNeverHit() {
		for classification: ClaudeCachedClassification in [.ambiguousIdentity, .identityUnresolvable] {
			XCTAssertFalse(
				cache().store(sha256: sha, launchProfileKey: key,
							  classification: classification, validation: .observedPassed),
				"\(classification) must not be stored — there is no identity to remember"
			)
			XCTAssertEqual(cache().lookup(sha256: sha, launchProfileKey: key), .miss(.noRecord))
			XCTAssertFalse(classification.isUsableAsAHit)
		}
	}

	/// Every classification is explicitly on one side of the usable line — a new case
	/// added without a decision fails here rather than defaulting to servable.
	func testEveryClassificationTokenHasAnExplicitUsabilityDecision() {
		let usable = ClaudeCachedClassification.allCases.filter(\.isUsableAsAHit)
		let unusable = ClaudeCachedClassification.allCases.filter { !$0.isUsableAsAHit }
		XCTAssertEqual(Set(unusable), [.ambiguousIdentity, .identityUnresolvable])
		XCTAssertEqual(usable.count, ClaudeCachedClassification.allCases.count - 2)
	}

	/// A manifest that could not be loaded must not masquerade as a loaded version.
	func testManifestFallbackDoesNotMasqueradeAsALoadedManifestVersion() {
		let fallback = environment(
			manifestVersion: ClaudeCompatibilityCacheEnvironment.unloadedManifestVersion)
		XCTAssertTrue(cache(fallback).store(sha256: sha, launchProfileKey: key,
											classification: .noExactMatch, validation: .observedPassed))

		// The record written under fallback must NOT be served once a real manifest
		// loads, and vice versa.
		XCTAssertEqual(cache().lookup(sha256: sha, launchProfileKey: key),
					   .miss(.manifestVersionChanged),
					   "a decision made with no manifest must not survive the manifest becoming available")

		XCTAssertNotEqual(ClaudeCompatibilityCacheEnvironment.unloadedManifestVersion, "2026-07-21.1")
		XCTAssertFalse(ClaudeCompatibilityCacheEnvironment.unloadedManifestVersion.isEmpty,
					   "an empty token would collide with an unset manifest version")
	}

	/// The record's field set is CLOSED. Anything outside the five axes plus the two
	/// result fields is a leak — of a capability grant, a credential, or a path.
	func testRecordEncodesOnlyTheFiveAxesAndTheResult() throws {
		seedBaseline()
		let record = ClaudeCompatibilityCacheRecord(
			sha256: sha, launchProfileKey: key, manifestVersion: "2026-07-21.1",
			appBuild: "build-100",
			probeSchemaVersion: ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion,
			classification: .exactCertified, validation: .observedPassed)
		let encoded = try JSONEncoder().encode(record)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

		XCTAssertEqual(
			Set(object.keys),
			["sha256", "launchProfileKey", "manifestVersion", "appBuild",
			 "probeSchemaVersion", "classification", "validation"],
			"the cache record's field set is closed — a new field is a deliberate schema change"
		)

		// And explicitly none of the forbidden ones (§1.3, R16).
		for forbidden in ["behaviorKey", "locallyValidated", "resume", "models",
						  "effortLevels", "fastModeState", "account", "sessionID",
						  "sessionId", "resolvedPath", "realPath", "environment"] {
			XCTAssertNil(object[forbidden], "the cache must never store `\(forbidden)`")
		}
	}

	/// The whole persisted blob must carry no home path, credential, or session id.
	func testPersistedBlobCarriesNoSensitiveMaterial() throws {
		seedBaseline()
		let raw = try XCTUnwrap(defaults.data(forKey: "claude.compatibility.cache.v1"))
		let text = String(decoding: raw, as: UTF8.self)
		XCTAssertFalse(text.contains(NSHomeDirectory()), "a raw home path reached the cache")
		for marker in ["ANTHROPIC", "api_key", "apiKey", "token", "Bearer", "/Users/"] {
			XCTAssertFalse(text.localizedCaseInsensitiveContains(marker),
						   "the persisted cache carries `\(marker)`")
		}
	}

	// MARK: - Bounding

	func testCacheIsBoundedToEightRecordsPruningOldestFirst() {
		let store = cache()
		for index in 0..<(ClaudeCompatibilityCache.maximumRecords + 3) {
			store.store(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: index),
						classification: .exactCertified, validation: .observedPassed)
		}
		// The three oldest are gone; the newest eight remain.
		for index in 0..<3 {
			XCTAssertNil(
				store.lookup(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: index)).record,
				"record \(index) should have been pruned as oldest")
		}
		for index in 3..<(ClaudeCompatibilityCache.maximumRecords + 3) {
			XCTAssertNotNil(
				store.lookup(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: index)).record,
				"record \(index) should still be present")
		}
	}

	func testRestoringAnExistingKeyRefreshesItsRecencyRatherThanDuplicating() {
		let store = cache()
		for index in 0..<ClaudeCompatibilityCache.maximumRecords {
			store.store(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: index),
						classification: .exactCertified, validation: .observedPassed)
		}
		// Touch the oldest, then add one more. The refreshed record must survive and
		// the SECOND-oldest must be the one pruned.
		store.store(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: 0),
					classification: .exactLimited, validation: .observedPassed)
		store.store(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: 999),
					classification: .exactCertified, validation: .observedPassed)

		XCTAssertEqual(
			store.lookup(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: 0)).record?.classification,
			.exactLimited, "a re-stored key must be treated as most recent")
		XCTAssertNil(store.lookup(sha256: sha, launchProfileKey: CacheTestKeys.key(seed: 1)).record,
					 "the second-oldest is now the oldest and must be pruned")
	}

	// MARK: - Build identity must be identifiable, or the store is disabled

	/// Every build lacking `CFBundleVersion` shares one `appBuild` token, so records
	/// written under it would be mutually comparable across genuinely different
	/// builds — the exact merge the axis exists to prevent. Fail closed instead.
	func testAnUnidentifiableBuildNeitherStoresNorReads() {
		let unidentified = ClaudeCompatibilityCacheEnvironment(
			manifestVersion: "2026-07-21.1",
			appBuild: ClaudeCompatibilityCacheEnvironment.unknownAppBuild,
			probeSchemaVersion: ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion)
		XCTAssertFalse(unidentified.hasIdentifiableBuild)

		let store = cache(unidentified)
		XCTAssertFalse(
			store.store(sha256: sha, launchProfileKey: key,
						classification: .exactCertified, validation: .observedPassed),
			"an unidentifiable build must not write a record")
		XCTAssertEqual(store.lookup(sha256: sha, launchProfileKey: key),
					   .miss(.buildIdentityUnavailable))
	}

	/// And a record written by an IDENTIFIED build must not be served to an
	/// unidentified one — the direction that would otherwise leak across builds.
	func testAnIdentifiedBuildsRecordIsNotServedToAnUnidentifiedBuild() {
		seedBaseline()
		let unidentified = cache(ClaudeCompatibilityCacheEnvironment(
			manifestVersion: "2026-07-21.1",
			appBuild: ClaudeCompatibilityCacheEnvironment.unknownAppBuild,
			probeSchemaVersion: ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion))
		XCTAssertEqual(unidentified.lookup(sha256: sha, launchProfileKey: key),
					   .miss(.buildIdentityUnavailable))
	}

	func testAnEmptyBuildStringIsAlsoUnidentifiable() {
		let blank = ClaudeCompatibilityCacheEnvironment(
			manifestVersion: "2026-07-21.1", appBuild: "",
			probeSchemaVersion: ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion)
		XCTAssertFalse(blank.hasIdentifiableBuild,
					   "an empty build string identifies nothing and must not group builds together")
	}

	// MARK: - Agreement: what the record is actually FOR

	/// The store saves no work — §3.1 validates unconditionally against the initialize
	/// response the child already produced. What a prior record CAN do is reveal that
	/// admission reached a different conclusion from identical inputs.
	func testAgreementDetectsDivergenceUnderIdenticalAxes() {
		XCTAssertEqual(
			ClaudeCompatibilityRecordAgreement.between(
				prior: nil, classification: .exactCertified, validation: .observedPassed),
			.noPriorRecord)

		seedBaseline(classification: .exactCertified, validation: .observedPassed)
		let prior = cache().lookup(sha256: sha, launchProfileKey: key).record

		XCTAssertEqual(
			ClaudeCompatibilityRecordAgreement.between(
				prior: prior, classification: .exactCertified, validation: .observedPassed),
			.agrees)

		let diverged = ClaudeCompatibilityRecordAgreement.between(
			prior: prior, classification: .exactLimited, validation: .observedPassed)
		XCTAssertEqual(diverged, .diverges(priorClassification: .exactCertified,
										   priorValidation: .observedPassed))
		XCTAssertTrue(diverged.isDivergent)

		// A differing VALIDATION diverges too — not only a differing classification.
		XCTAssertTrue(ClaudeCompatibilityRecordAgreement.between(
			prior: prior, classification: .exactCertified, validation: .observedFailed).isDivergent)
	}

	// MARK: - Typed axes (the axes are digests, not strings)

	/// The two identity axes are both SHA-256 digests. An untyped API makes swapping
	/// them a bug that compiles — and a durable store is exactly where a swapped
	/// digest survives to be believed on a later launch.
	func testSwappingTheTwoIdentityAxesDoesNotHit() {
		seedBaseline()
		// `key.digest` is a ClaudeSHA256, so this is only expressible by deliberately
		// reinterpreting it — which is what the typed API prevents at every call site.
		let swappedAsSHA = key.digest
		XCTAssertNil(cache().lookup(sha256: swappedAsSHA, launchProfileKey: key).record,
					 "the profile digest used as the binary hash must not hit")
	}

	/// A persisted digest that is not a well-formed SHA-256 decoded cleanly but is
	/// corruption. It must read as corrupt, never be compared as an ordinary string.
	func testPersistedRecordWithAMalformedDigestReadsAsCorrupt() throws {
		seedBaseline()
		let raw = try XCTUnwrap(defaults.data(forKey: "claude.compatibility.cache.v1"))
		var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
		var entries = try XCTUnwrap(envelope["entries"] as? [String: Any])
		let storageKey = ClaudeCompatibilityCache.storageKey(sha256: sha, launchProfileKey: key)

		// A structurally valid record whose sha256 is too short.
		let tampered: [String: Any] = [
			"sha256": "deadbeef",
			"launchProfileKey": key.digest.value,
			"manifestVersion": "2026-07-21.1", "appBuild": "build-100",
			"probeSchemaVersion": ClaudeCompatibilityCacheEnvironment.currentProbeSchemaVersion,
			"classification": "exactCertified", "validation": "observedPassed",
		]
		entries[storageKey] = try JSONSerialization.data(withJSONObject: tampered).base64EncodedString()
		envelope["entries"] = entries
		defaults.set(try JSONSerialization.data(withJSONObject: envelope),
					 forKey: "claude.compatibility.cache.v1")

		XCTAssertEqual(cache().lookup(sha256: sha, launchProfileKey: key), .miss(.corruptRecord),
					   "a malformed persisted digest must read as corrupt, not be string-compared")
	}
}

/// Deterministic launch-profile keys for cache tests.
enum CacheTestKeys {
	static func key(seed: Int) -> ClaudeLaunchProfileKey {
		ClaudeLaunchProfileKey(input: ClaudeLaunchProfileKeyInput(
			commandNameClass: .explicitPath,
			resumeRequested: seed % 2 == 0,
			modelRoute: .defaultRoute,
			effortClass: .defaultEffort,
			permissionModeClass: .requireApproval,
			backendClass: .standardClaude,
			authenticationModeClass: .userManagedSubscription,
			workingDirectoryClass: .workspaceRoot,
			mcpConfigPresent: true,
			mcpStrictMode: true,
			disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: ["seed-\(seed)"])))
	}
}