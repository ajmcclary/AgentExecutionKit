import CryptoKit
import Foundation
import Security
import Darwin
import AgentProcessSupport
import ClaudeRuntimeKit

/// `realpath(3)` plus `CommandPathResolver.launchability`.
public struct ClaudeExecutableFileSystemProbe: ClaudeExecutableFileSystemProbing {
    private let checkLaunchability: (String) -> AgentExecutableLaunchability
    public init(launchability: @escaping (String) -> AgentExecutableLaunchability) {
        checkLaunchability = launchability
    }
	public func launchability(ofResolvedCommand command: String) -> AgentExecutableLaunchability {
		checkLaunchability(command)
	}

	public func canonicalPath(ofResolvedCommand command: String) -> String? {
		// realpath(3) rather than URL.resolvingSymlinksInPath(): the latter
		// silently returns its input when resolution fails, which would let a
		// broken symlink chain masquerade as a canonical path.
		guard let resolved = realpath(command, nil) else { return nil }
		defer { free(resolved) }
		return String(cString: resolved)
	}
}

/// Streaming SHA-256 that yields the byte count from the SAME read, so size needs
/// no separate `stat` and has no independent failure mode.
public struct ClaudeExecutableHasher: ClaudeExecutableHashing {
	private let chunkSize: Int

	public init(chunkSize: Int = 1 << 20) {
		// A non-positive size is silently catastrophic rather than merely wrong:
		// `read(upToCount: 0)` returns empty immediately, so the loop ends on its
		// first iteration and a non-empty file hashes to the EMPTY digest with
		// size 0 — a plausible-looking result that is entirely false.
		self.chunkSize = max(1, chunkSize)
	}

	public func hashAndSize(atCanonicalPath path: String) -> (sha256: ClaudeSHA256, sizeBytes: Int)? {
		guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
		defer { try? handle.close() }

		var hasher = SHA256()
		var total = 0
		while true {
			let chunk: Data?
			do {
				chunk = try handle.read(upToCount: chunkSize)
			} catch {
				return nil
			}
			guard let chunk, !chunk.isEmpty else { break }
			hasher.update(data: chunk)
			total += chunk.count
		}

		// Lowercase hex explicitly: `ClaudeSHA256` rejects any other case rather
		// than normalising, so producing it correctly is this adapter's job.
		let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
		guard let sha256 = ClaudeSHA256(digest) else { return nil }
		return (sha256, total)
	}
}

/// Security.framework signing classification for an arbitrary path.
///
/// Mirrors `RuntimeCodeSigningDetector`'s idioms, but that type inspects the
/// CURRENT PROCESS via `SecCodeCopySelf`; identifying another executable needs
/// `SecStaticCodeCreateWithPath`.
///
/// No outcome ever fails identification: signing state is a classification, never
/// a reason to make a runtime unresolvable. Failures split by KIND —
/// `.unreadable` when the signature cannot be inspected at all, `.invalid` when it
/// is readable but does not validate. Collapsing those would hide tampering behind
/// a word that sounds like a tooling problem.
///
/// Classification order is load-bearing: integrity is checked BEFORE any
/// provenance flag, so a tampered binary cannot be reported by the provenance it
/// merely claims.
public struct ClaudeExecutableSigningInspector: ClaudeExecutableSigningInspecting {
    private let validateTeamIdentifier: @Sendable (String) -> Bool
    public init(validateTeamIdentifier: @escaping @Sendable (String) -> Bool) {
        self.validateTeamIdentifier = validateTeamIdentifier
    }
	public func signingClass(atCanonicalPath path: String) -> ClaudeExecutableSigningClass {
		var staticCode: SecStaticCode?
		let url = URL(fileURLWithPath: path) as CFURL
		guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
			  let staticCode
		else { return .unreadable }

		var information: CFDictionary?
		guard SecCodeCopySigningInformation(
			staticCode,
			SecCSFlags(rawValue: kSecCSSigningInformation),
			&information
		) == errSecSuccess,
			let dictionary = information as? [String: Any]
		else { return .unreadable }

		// No identifier at all means the binary carries no signature.
		let identifier = (dictionary[kSecCodeInfoIdentifier as String] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let identifier, !identifier.isEmpty else { return .unsigned }

		// INTEGRITY BEFORE PROVENANCE. A nil-requirement strict validation checks
		// integrity, not anchor, so it accepts an intact ad-hoc signature. Consulting
		// the ad-hoc flag first would therefore report a TAMPERED ad-hoc binary as
		// `.adHoc` — readable metadata masking a broken code directory. Verified:
		// re-signing a copy of /bin/ls with `codesign --sign -` validates, and
		// flipping one byte makes this call return -67061 while the flag stays set.
		guard SecStaticCodeCheckValidity(staticCode, Self.strictFlags, nil) == errSecSuccess else {
			return .invalid
		}

		// Security.framework declares kSecCodeSignatureAdhoc as the 0x0002 flag, but
		// this SDK does not surface that C enum case to Swift — same workaround, and
		// same reasoning, as `RuntimeCodeSigningDetector.adHocSignature(from:)`.
		if let flags = dictionary[kSecCodeInfoFlags as String] as? NSNumber {
			let adHocMask = SecCodeSignatureFlags(rawValue: 0x0002).rawValue
			if flags.uint32Value & adHocMask != 0 { return .adHoc }
		}

		let team = (dictionary[kSecCodeInfoTeamIdentifier as String] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		if let team, !team.isEmpty,
		   satisfiesDeveloperIDRequirement(staticCode, teamIdentifier: team) {
			return .appleDeveloperID
		}

		// Platform binaries carry a platform identifier and no team identifier.
		if let platform = dictionary[kSecCodeInfoPlatformIdentifier as String] as? NSNumber,
		   platform.intValue != 0 {
			return .applePlatform
		}

		// Valid, but neither Developer ID nor platform: Apple Development,
		// enterprise, or another anchor.
		return .otherSigned
	}

	/// Strict validation across every architecture, matching
	/// `RuntimeCodeSigningDetector`. Without these a fat binary can pass on one
	/// slice while another is unsigned or tampered.
	private static let strictFlags = SecCSFlags(
		rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
	)

	/// A team identifier is a *claim*, not proof, and `anchor apple generic` plus a
	/// subject-OU match is satisfied by an Apple **Development** certificate too —
	/// which would label a development build as a distributed one. The Developer ID
	/// Application marker OID (1.2.840.113635.100.6.1.13) is what actually
	/// distinguishes them.
	private func satisfiesDeveloperIDRequirement(
		_ staticCode: SecStaticCode,
		teamIdentifier: String
	) -> Bool {
		guard validateTeamIdentifier(teamIdentifier) else {
			return false
		}
		let requirementText = """
			anchor apple generic \
			and certificate leaf[field.1.2.840.113635.100.6.1.13] \
			and certificate leaf[subject.OU] = "\(teamIdentifier)"
			"""
		var requirement: SecRequirement?
		guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
				== errSecSuccess,
			  let requirement
		else { return false }
		return SecStaticCodeCheckValidity(staticCode, Self.strictFlags, requirement) == errSecSuccess
	}
}
