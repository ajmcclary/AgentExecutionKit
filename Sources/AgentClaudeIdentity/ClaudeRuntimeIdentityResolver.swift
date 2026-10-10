import Foundation
import AgentProcessSupport
import ClaudeRuntimeKit

/// Ordered, caller-owned identity resolution. Hosts inject collaborators and home path.
/// This preserves compatibility identity semantics; hashing is not an atomic exec guarantee.
// MARK: - Injected collaborators

public protocol ClaudeExecutableFileSystemProbing {
	func launchability(ofResolvedCommand command: String) -> AgentExecutableLaunchability
	/// Fully resolved canonical path (symlinks followed), or nil if it cannot be
	/// determined.
	func canonicalPath(ofResolvedCommand command: String) -> String?
}

public protocol ClaudeExecutableHashing {
	/// Hash and byte count from a SINGLE read of the canonical path. Size is
	/// derived here rather than by a separate `stat`, so there is no independent
	/// metadata failure mode to classify.
	func hashAndSize(atCanonicalPath path: String) -> (sha256: ClaudeSHA256, sizeBytes: Int)?
}

public protocol ClaudeExecutableSigningInspecting {
	/// Never fails: an unreadable signature classifies as `.unreadable` rather
	/// than failing identification.
	func signingClass(atCanonicalPath path: String) -> ClaudeExecutableSigningClass
}

// MARK: - Resolver

public struct ClaudeRuntimeIdentityResolver {
	private let fileSystem: ClaudeExecutableFileSystemProbing
	private let hasher: ClaudeExecutableHashing
	private let signingInspector: ClaudeExecutableSigningInspecting
	private let homeDirectory: String

	public init(
		fileSystem: ClaudeExecutableFileSystemProbing,
		hasher: ClaudeExecutableHashing,
		signingInspector: ClaudeExecutableSigningInspecting,
		homeDirectory: String
	) {
		self.fileSystem = fileSystem
		self.hasher = hasher
		self.signingInspector = signingInspector
		self.homeDirectory = homeDirectory
	}

	public func resolve(resolvedCommand: String) -> ClaudeRuntimeResolution {
		// 1. Launchability, mapped exhaustively. `CommandPathResolver` returns a
		//    bare command when every strategy fails, and returns candidate paths
		//    without requiring an executable regular file.
		switch fileSystem.launchability(ofResolvedCommand: resolvedCommand) {
		case .bareCommandFallback:
			return .unresolvable(.noPath)
		case .missingPath:
			return .unresolvable(.missingPath)
		case .directory:
			return .unresolvable(.isDirectory)
		case .notExecutable:
			return .unresolvable(.notExecutable)
		case .launchable:
			break
		}

		// 2. Canonicalise BEFORE classification: path class describes where the
		//    real bytes live, not where a shim happens to sit.
		guard let canonicalPath = fileSystem.canonicalPath(ofResolvedCommand: resolvedCommand),
			  !canonicalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return .unresolvable(.canonicalPathUnreadable)
		}

		// 3. Hash and size from one read of the canonical bytes.
		guard let digest = hasher.hashAndSize(atCanonicalPath: canonicalPath) else {
			return .unresolvable(.hashUnreadable)
		}

		// 4. Signing never fails identification.
		let signingClass = signingInspector.signingClass(atCanonicalPath: canonicalPath)

		guard let identity = ClaudeRuntimeIdentity(
			resolvedPath: resolvedCommand,
			realPath: canonicalPath,
			sha256: digest.sha256,
			sizeBytes: digest.sizeBytes,
			signingClass: signingClass,
			pathClass: Self.pathClass(forCanonicalPath: canonicalPath, homeDirectory: homeDirectory)
		) else {
			// Only reachable if the canonical path is blank, already screened above.
			return .unresolvable(.canonicalPathUnreadable)
		}
		return .resolved(identity)
	}

	/// Telemetry-only classification (never a downgrade input). Derived from the
	/// CANONICAL path so a shim does not misreport where the bytes live.
	public static func pathClass(forCanonicalPath path: String, homeDirectory: String) -> ClaudeExecutablePathClass {
		let home = homeDirectory
		// Global npm installs live under a `lib/node_modules` root. Matching a bare
		// "/node_modules/" would classify every PROJECT-LOCAL dependency as a global
		// install and misstate provenance. Checked before Homebrew so a
		// Homebrew-hosted global package reports the more specific provenance.
		if path.contains("/lib/node_modules/") {
			return .npmGlobal
		}
		if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/Cellar/") {
			return .homebrew
		}
		if path.hasPrefix("\(home)/.local/") || path.hasPrefix("\(home)/.claude/") ||
			path.hasPrefix("\(home)/.npm-global/") || path.hasPrefix("\(home)/.nvm/") {
			return .userLocal
		}
		if path.hasPrefix("/usr/bin/") || path.hasPrefix("/usr/sbin/") ||
			path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") {
			return .system
		}
		return .unknown
	}
}
