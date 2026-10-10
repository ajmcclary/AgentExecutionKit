import Foundation
import Synchronization
import ClaudeRuntimeKit
import AIClientStorage

// Item 11 — the DURABLE EXACT-IDENTITY RECORD STORE (plan §1.3), at R16's reserved
// location.
//
// WHAT THIS IS, STATED HONESTLY. §1.3 calls this a "cache", and an earlier revision
// of this file repeated that word along with the claim that an axis miss "forces
// re-validation". Both were wrong about causality, and the tests could not have
// caught it because they only exercised the store:
//
//   * a MISS forces nothing. Phase B validates unconditionally, on every launch, hit
//     or miss. There is no branch anywhere that a miss could take.
//   * a HIT saves nothing. §3.1 deliberately validates against the initialize
//     response THE PRODUCTION CHILD HAS ALREADY PRODUCED — no second process, no
//     probe, no extra timeout — so the work a hit could skip is a dictionary read.
//     The one genuinely costly input, the binary SHA-256, must be computed BEFORE a
//     lookup because it is half the key.
//
// So this is a durable OBSERVATION HISTORY, not a work-saving cache. Keeping the
// "cache" vocabulary while behaving like history is how a component quietly acquires
// authority nobody granted it — the next reader assumes a hit short-circuits
// something, and writes code that makes it true.
//
// WHAT IT IS FOR. The five axes make a prior record COMPARABLE to the current launch:
// same binary, same launch profile, same manifest, same app build, same probe schema.
// When all five match and the outcome DIFFERS, admission is non-deterministic for a
// fixed input, which is worth surfacing and is invisible without a durable record.
// That is the lookup's actual job (`ClaudeCompatibilityRecordAgreement`), and it is
// an observation, never a decision.
//
// WHAT IT MUST NEVER DO, enforced by the tests and by R16:
//
//   * infer a behaviour family, or upgrade an unknown binary to a known one —
//     admission is exact-identity-only (rev 5). An unknown hash records AS unknown.
//   * grant resume, or record any per-capability grant.
//   * persist models, effort levels, fast-mode state, or any other dynamic
//     capability — those are session-scoped (§1.3, R15f) and die with the epoch.
//   * store credentials, account fields, session identifiers, raw paths, or raw
//     environment data (§8).
//   * decide anything. A lookup returns a RECORD. Known-bad precedence and the
//     enforcement stage are re-applied by the coordinator from the live manifest on
//     every launch, before any lookup happens.

// MARK: - The cached outcome vocabulary

/// The classification, flattened to a stable token.
///
/// Deliberately a small closed vocabulary rather than the coordinator's rich type:
/// a durable record must survive code churn, and encoding an enum with associated
/// values would make the cache schema move whenever the classification type moves.
/// A token that no longer decodes is simply a miss.
public enum ClaudeCachedClassification: String, Codable, Equatable, CaseIterable, Sendable {
	case exactCertified
	case exactLimited
	case exactExternalOnly
	/// No exact identity match. Cached so a repeat launch of an unknown binary need
	/// not re-derive it — never so the binary becomes known.
	case noExactMatch
	/// More than one family bound the identity. NEVER usable: see `isUsableAsAHit`.
	case ambiguousIdentity
	case knownBadMatch
	case identityUnresolvable

	/// Whether a record carrying this classification may be returned as a HIT.
	///
	/// `ambiguousIdentity` and `identityUnresolvable` are excluded. Both mean the identity
	/// itself could not be established, so there is nothing a cache can legitimately
	/// remember about it — and a cached ambiguity would be a stored guess about which
	/// family won, which is exactly the inference this design forbids.
	public var isUsableAsAHit: Bool {
		switch self {
		case .exactCertified, .exactLimited, .exactExternalOnly, .noExactMatch, .knownBadMatch:
			return true
		case .ambiguousIdentity, .identityUnresolvable:
			return false
		}
	}
}

/// The validation outcome, flattened the same way and for the same reason. The
/// specific failure REASON is not cached: it is a diagnostic, it churns, and a
/// consumer that branched on it would be branching on stale text.
public enum ClaudeCachedValidation: String, Codable, Equatable, CaseIterable, Sendable {
	case notObserved
	case observedPassed
	case observedFailed
}

// MARK: - The record

/// One cached exact-identity result. Every stored field is either an invalidation
/// axis or the result itself; there is no third category, by construction.
public struct ClaudeCompatibilityCacheRecord: Codable, Equatable, Sendable {

	// --- The five invalidation axes -----------------------------------------
	//
	// Stored as `String` because that is what JSON round-trips, but NEVER accepted or
	// returned as a bare `String`: the API takes `ClaudeSHA256` and
	// `ClaudeLaunchProfileKey`, and `decodedIdentity` re-validates on the way out.
	// With two same-typed digest fields, an untyped API makes a SHA/profile swap a
	// silent bug that compiles — and a persisted store is exactly where a swapped or
	// truncated digest would survive to be believed later.
	public let sha256: String
	public let launchProfileKey: String
	public let manifestVersion: String
	public let appBuild: String
	public let probeSchemaVersion: Int

	// --- The cached result ---------------------------------------------------
	public let classification: ClaudeCachedClassification
	public let validation: ClaudeCachedValidation

	public init(sha256: ClaudeSHA256,
		 launchProfileKey: ClaudeLaunchProfileKey,
		 manifestVersion: String,
		 appBuild: String,
		 probeSchemaVersion: Int,
		 classification: ClaudeCachedClassification,
		 validation: ClaudeCachedValidation) {
		self.sha256 = sha256.value
		self.launchProfileKey = launchProfileKey.digest.value
		self.manifestVersion = manifestVersion
		self.appBuild = appBuild
		self.probeSchemaVersion = probeSchemaVersion
		self.classification = classification
		self.validation = validation
	}

	/// The stored digests, re-parsed. `nil` when either persisted string is not a
	/// well-formed SHA-256 — a record that cannot restate its own identity is not a
	/// record, it is 64 bytes of hope, and must read as corrupt rather than as a hit.
	public var decodedIdentity: (sha256: ClaudeSHA256, launchProfileDigest: ClaudeSHA256)? {
		guard let sha = ClaudeSHA256(sha256),
			  let profile = ClaudeSHA256(launchProfileKey) else { return nil }
		return (sha, profile)
	}

	/// Whether this record was produced under the CURRENT environment. All five, all
	/// independent — a helper that checked four would be a silent one-axis hole.
	public func matches(_ environment: ClaudeCompatibilityCacheEnvironment,
				 sha256 expectedSHA: ClaudeSHA256,
				 launchProfileKey expectedKey: ClaudeLaunchProfileKey) -> Bool {
		sha256 == expectedSHA.value
			&& launchProfileKey == expectedKey.digest.value
			&& manifestVersion == environment.manifestVersion
			&& appBuild == environment.appBuild
			&& probeSchemaVersion == environment.probeSchemaVersion
	}
}

/// The current environment's three non-identity axes.
public struct ClaudeCompatibilityCacheEnvironment: Equatable, Sendable {
	public let manifestVersion: String
	public let appBuild: String
	public let probeSchemaVersion: Int

    public init(manifestVersion: String, appBuild: String, probeSchemaVersion: Int) {
        self.manifestVersion = manifestVersion; self.appBuild = appBuild
        self.probeSchemaVersion = probeSchemaVersion
    }

	/// The version token for a manifest that could NOT be loaded.
	///
	/// A fallback must never masquerade as a loaded manifest version. If both used
	/// the same token, a decision made under "no families and no rules" (§10.1) would
	/// be indistinguishable from one made under the real manifest — and would keep
	/// being served after the real manifest became available again. This token can
	/// never equal a real `manifestVersion`, which is always a date-stamped string.
	public static let unloadedManifestVersion = "__manifest-unavailable__"

	/// The probe schema version of the validation that feeds this cache. Bump when
	/// the §3.1 observation changes shape, so records produced under the old
	/// observation stop being served.
	public static let currentProbeSchemaVersion = 1

	public static let unknownAppBuild = "__app-build-unavailable__"

	/// Whether this environment's build can be told apart from another build's.
	///
	/// The fallback token is deliberately NOT treated as a build identity: it is one
	/// value shared by every build that lacks `CFBundleVersion`, so records written
	/// under it would be mutually comparable across genuinely different builds. When
	/// this is false the store neither reads nor writes — fail closed, no history at
	/// all, rather than history that silently merges builds.
	public var hasIdentifiableBuild: Bool { appBuild != Self.unknownAppBuild && !appBuild.isEmpty }


}

// MARK: - Lookup result

/// A lookup answers only "is there a usable record?" — never "what should happen?".
public enum ClaudeCompatibilityCacheLookup: Equatable, Sendable {
	case hit(ClaudeCompatibilityCacheRecord)
	case miss(Reason)

	public enum Reason: String, Equatable, Sendable {
		case noRecord
		/// Stored bytes did not decode, or decoded to a record that cannot restate its
		/// own identity. Treated exactly as absence, then overwritten on the next store
		/// (§10.2, "cache corrupt → treat as miss, re-validate, overwrite" — the
		/// re-validation happens regardless; what this controls is only whether a prior
		/// record is comparable).
		case corruptRecord
		/// This build cannot identify itself, so no record may be read or written under
		/// it (see `ClaudeCompatibilityCacheEnvironment.live`).
		case buildIdentityUnavailable
		case identityChanged
		case launchProfileChanged
		case manifestVersionChanged
		case appBuildChanged
		case probeSchemaVersionChanged
		/// The record exists and matches, but its classification is one that may never
		/// be served (ambiguous or unresolvable identity).
		case classificationNotCacheable
	}

	public var record: ClaudeCompatibilityCacheRecord? {
		if case .hit(let record) = self { return record }
		return nil
	}
}

// MARK: - Agreement between a prior record and the current outcome

/// What a prior comparable record says about the outcome just computed.
///
/// This is the lookup's REASON TO EXIST. All five axes matching means the inputs are
/// the same, so a differing outcome means admission is non-deterministic for a fixed
/// input — a real defect, and one that is invisible without a durable record.
/// Recorded as an observation; it never feeds a decision.
public enum ClaudeCompatibilityRecordAgreement: Equatable, Sendable {
	/// No comparable prior record.
	case noPriorRecord
	/// A prior record exists under identical axes and agrees.
	case agrees
	/// A prior record exists under identical axes and DISAGREES.
	case diverges(priorClassification: ClaudeCachedClassification,
				  priorValidation: ClaudeCachedValidation)

	public static func between(
		prior: ClaudeCompatibilityCacheRecord?,
		classification: ClaudeCachedClassification,
		validation: ClaudeCachedValidation
	) -> ClaudeCompatibilityRecordAgreement {
		guard let prior else { return .noPriorRecord }
		if prior.classification == classification && prior.validation == validation {
			return .agrees
		}
		return .diverges(priorClassification: prior.classification, priorValidation: prior.validation)
	}

	public var isDivergent: Bool { if case .diverges = self { return true }; return false }
}

// MARK: - The store

/// Explicitly namespaced observation store with injected Data preferences. Calls on this instance serialize
/// complete read/modify/write transactions. Hosts own namespace and instance lifetime.
/// Bounded to the 8 most-recent keys, oldest pruned (§1.3).
public final class ClaudeCompatibilityCache: Sendable {

	private let namespace: String
	public static let maximumRecords = 8

	private let preferences: any AIDataPreferences
	private let transaction = Mutex(())
	public let environment: ClaudeCompatibilityCacheEnvironment

	public init(preferences: any AIDataPreferences, namespace: String, environment: ClaudeCompatibilityCacheEnvironment) {
		self.namespace = namespace
		self.preferences = preferences
		self.environment = environment
	}

	/// `sha256 ‖ launchProfileKey` (§1.3). Nothing else contributes: not the model,
	/// not the effort, not a session id.
	public static func storageKey(sha256: ClaudeSHA256, launchProfileKey: ClaudeLaunchProfileKey) -> String {
		"\(sha256.value)|\(launchProfileKey.digest.value)"
	}

	// MARK: Lookup

	public func lookup(sha256: ClaudeSHA256,
				launchProfileKey: ClaudeLaunchProfileKey) -> ClaudeCompatibilityCacheLookup {
		return transaction.withLock { _ in
			// A build that cannot identify itself must not read a record, because every
			// such build shares one `appBuild` value: a record written by one unidentified
			// build would otherwise be comparable to a different unidentified build, which
			// is exactly what the axis exists to prevent.
			guard environment.hasIdentifiableBuild else { return .miss(.buildIdentityUnavailable) }
			let entries = loadEntries()
			guard let stored = entries[Self.storageKey(sha256: sha256, launchProfileKey: launchProfileKey)] else {
				return .miss(.noRecord)
			}
			guard let record = try? JSONDecoder().decode(ClaudeCompatibilityCacheRecord.self, from: stored) else {
				return .miss(.corruptRecord)
			}
			// Decoding proves the SHAPE. This proves the VALUES: a persisted digest that is
			// not a well-formed SHA-256 is corruption that decoded cleanly, and is the one
			// way a malformed axis could otherwise be compared as an ordinary string.
			guard record.decodedIdentity != nil else { return .miss(.corruptRecord) }
			let sha256 = sha256.value
			let launchProfileKey = launchProfileKey.digest.value
			// Each axis reported separately so a miss names WHICH axis made the prior
			// record incomparable — the five independent-axis tests assert on these
			// reasons, so a collapsed "stale" reason would make them indistinguishable.
			if record.sha256 != sha256 { return .miss(.identityChanged) }
			if record.launchProfileKey != launchProfileKey { return .miss(.launchProfileChanged) }
			if record.manifestVersion != environment.manifestVersion { return .miss(.manifestVersionChanged) }
			if record.appBuild != environment.appBuild { return .miss(.appBuildChanged) }
			if record.probeSchemaVersion != environment.probeSchemaVersion {
				return .miss(.probeSchemaVersionChanged)
			}
			guard record.classification.isUsableAsAHit else {
				return .miss(.classificationNotCacheable)
			}
			return .hit(record)
		}
	}

	// MARK: Store

	/// Records an outcome. An unusable classification is NOT stored: writing an
	/// ambiguous or unresolvable result would only ever produce a
	/// `classificationNotCacheable` miss later, while occupying one of the eight slots.
	@discardableResult
	public func store(
		sha256: ClaudeSHA256,
		launchProfileKey: ClaudeLaunchProfileKey,
		classification: ClaudeCachedClassification,
		validation: ClaudeCachedValidation
	) -> Bool {
		return transaction.withLock { _ in
			guard environment.hasIdentifiableBuild else { return false }
			guard classification.isUsableAsAHit else { return false }
			let record = ClaudeCompatibilityCacheRecord(
				sha256: sha256,
				launchProfileKey: launchProfileKey,
				manifestVersion: environment.manifestVersion,
				appBuild: environment.appBuild,
				probeSchemaVersion: environment.probeSchemaVersion,
				classification: classification,
				validation: validation)
			guard let encoded = try? JSONEncoder().encode(record) else { return false }

			let key = Self.storageKey(sha256: sha256, launchProfileKey: launchProfileKey)
			var order = loadOrder().filter { $0 != key }
			var entries = loadEntries()
			entries[key] = encoded
			order.append(key)

			// Bounded, oldest pruned. Insertion order is tracked explicitly because a
			// dictionary has none, and "most recent" would otherwise be whatever the hash
			// table happened to enumerate last.
			while order.count > Self.maximumRecords {
				let oldest = order.removeFirst()
				entries.removeValue(forKey: oldest)
			}
			persist(entries: entries, order: order)
			return true
		}
	}

	public func removeAll() {
		transaction.withLock { _ in preferences.remove(forKey: namespace) }
	}

	// MARK: Backing store

	private struct Envelope: Codable {
		var order: [String]
		var entries: [String: Data]
	}

	private func loadEnvelope() -> Envelope? {
		guard let raw = preferences.data(forKey: namespace) else { return nil }
		return try? JSONDecoder().decode(Envelope.self, from: raw)
	}

	private func loadEntries() -> [String: Data] { loadEnvelope()?.entries ?? [:] }
	private func loadOrder() -> [String] { loadEnvelope()?.order ?? [] }

	private func persist(entries: [String: Data], order: [String]) {
		guard let encoded = try? JSONEncoder().encode(Envelope(order: order, entries: entries)) else {
			return
		}
		preferences.set(encoded, forKey: namespace)
	}
}
