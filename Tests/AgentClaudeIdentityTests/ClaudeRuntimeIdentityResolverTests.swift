import XCTest
@testable import AgentClaudeIdentity
import AgentProcessSupport
import ClaudeRuntimeKit

/// Item 1 of the compatibility-admission plan. The resolver is the SOLE owner of
/// filesystem and process reads for runtime identity (R15a), and is deliberately
/// uncalled in item 1 — nothing here changes launch behavior.
///
/// Collaborators are narrow and injected so every failure mode is deterministic;
/// the resolver stays the single orchestration owner.
final class ClaudeRuntimeIdentityResolverTests: XCTestCase {

	private let hex = String(repeating: "ab12cd34", count: 8)

	// MARK: - Fakes with shared call recording
	//
	// Recording every collaborator call WITH its path argument is what proves the
	// canonical path — not the resolved command — reaches hashing and signing, and
	// that a failure short-circuits the reads after it.

	private final class CallRecorder {
		enum Call: Equatable, CustomStringConvertible {
			case launchability(String)
			case canonicalPath(String)
			case hash(String)
			case signing(String)

			var description: String {
				switch self {
				case .launchability(let p): return "launchability(\(p))"
				case .canonicalPath(let p): return "canonicalPath(\(p))"
				case .hash(let p): return "hash(\(p))"
				case .signing(let p): return "signing(\(p))"
				}
			}
		}
		private(set) var calls: [Call] = []
		func record(_ call: Call) { calls.append(call) }
	}

	private struct FakeFileSystem: ClaudeExecutableFileSystemProbing {
		let recorder: CallRecorder
		var launchability: AgentExecutableLaunchability = .launchable
		var canonicalPath: String? = "/opt/homebrew/Cellar/claude/2.1.216/bin/claude"
		func launchability(ofResolvedCommand command: String) -> AgentExecutableLaunchability {
			recorder.record(.launchability(command))
			return launchability
		}
		func canonicalPath(ofResolvedCommand command: String) -> String? {
			recorder.record(.canonicalPath(command))
			return canonicalPath
		}
	}

	private struct FakeHasher: ClaudeExecutableHashing {
		let recorder: CallRecorder
		var result: (sha256: ClaudeSHA256, sizeBytes: Int)?
		func hashAndSize(atCanonicalPath path: String) -> (sha256: ClaudeSHA256, sizeBytes: Int)? {
			recorder.record(.hash(path))
			return result
		}
	}

	private struct FakeSigningInspector: ClaudeExecutableSigningInspecting {
		let recorder: CallRecorder
		var signingClass: ClaudeExecutableSigningClass = .appleDeveloperID
		func signingClass(atCanonicalPath path: String) -> ClaudeExecutableSigningClass {
			recorder.record(.signing(path))
			return signingClass
		}
	}

	private func makeResolver(
		recorder: CallRecorder,
		launchability: AgentExecutableLaunchability = .launchable,
		canonicalPath: String? = "/opt/homebrew/Cellar/claude/2.1.216/bin/claude",
		hash: (sha256: ClaudeSHA256, sizeBytes: Int)?? = nil,
		signingClass: ClaudeExecutableSigningClass = .appleDeveloperID
	) -> ClaudeRuntimeIdentityResolver {
		ClaudeRuntimeIdentityResolver(
			fileSystem: FakeFileSystem(recorder: recorder, launchability: launchability,
									   canonicalPath: canonicalPath),
			hasher: FakeHasher(recorder: recorder,
							   result: hash ?? (ClaudeSHA256(hex)!, 249_225_584)),
			signingInspector: FakeSigningInspector(recorder: recorder, signingClass: signingClass),
            homeDirectory: "/host/home"
		)
	}

	// MARK: - Collaborator handoff and ordering

	func testCollaboratorsReceiveExpectedPathsInOrder() {
		let recorder = CallRecorder()
		let canonical = "/opt/homebrew/Cellar/claude/2.1.216/bin/claude"
		_ = makeResolver(recorder: recorder, canonicalPath: canonical)
			.resolve(resolvedCommand: "/opt/homebrew/bin/claude")
		XCTAssertEqual(recorder.calls, [
			.launchability("/opt/homebrew/bin/claude"),
			.canonicalPath("/opt/homebrew/bin/claude"),
			.hash(canonical),      // canonical, NOT the resolved command
			.signing(canonical)
		])
	}

	func testLaunchabilityFailureShortCircuitsEverything() {
		let recorder = CallRecorder()
		_ = makeResolver(recorder: recorder, launchability: .missingPath)
			.resolve(resolvedCommand: "/nope/claude")
		XCTAssertEqual(recorder.calls, [.launchability("/nope/claude")])
	}

	func testCanonicalPathFailureShortCircuitsHashingAndSigning() {
		let recorder = CallRecorder()
		_ = makeResolver(recorder: recorder, canonicalPath: nil)
			.resolve(resolvedCommand: "/bin/claude")
		XCTAssertEqual(recorder.calls, [
			.launchability("/bin/claude"),
			.canonicalPath("/bin/claude")
		])
	}

	func testHashFailureShortCircuitsSigning() {
		let recorder = CallRecorder()
		let canonical = "/opt/homebrew/Cellar/claude/2.1.216/bin/claude"
		_ = makeResolver(recorder: recorder, hash: .some(nil))
			.resolve(resolvedCommand: "/bin/claude")
		XCTAssertEqual(recorder.calls, [
			.launchability("/bin/claude"),
			.canonicalPath("/bin/claude"),
			.hash(canonical)
		])
	}

	// MARK: - Launchability mapping (exhaustive)

	func testBareCommandFallbackIsUnresolvableNoPath() {
		let resolver = makeResolver(recorder: CallRecorder(), launchability: .bareCommandFallback)
		XCTAssertEqual(resolver.resolve(resolvedCommand: "claude"), .unresolvable(.noPath))
	}

	func testMissingPathIsUnresolvable() {
		let resolver = makeResolver(recorder: CallRecorder(), launchability: .missingPath)
		XCTAssertEqual(resolver.resolve(resolvedCommand: "/nope/claude"), .unresolvable(.missingPath))
	}

	func testDirectoryIsUnresolvable() {
		let resolver = makeResolver(recorder: CallRecorder(), launchability: .directory)
		XCTAssertEqual(resolver.resolve(resolvedCommand: "/tmp"), .unresolvable(.isDirectory))
	}

	func testNotExecutableIsUnresolvable() {
		let resolver = makeResolver(recorder: CallRecorder(), launchability: .notExecutable)
		XCTAssertEqual(resolver.resolve(resolvedCommand: "/tmp/x"), .unresolvable(.notExecutable))
	}

	// MARK: - Canonical path

	func testCanonicalPathFailureIsItsOwnReason() {
		XCTAssertEqual(makeResolver(recorder: CallRecorder(), canonicalPath: nil).resolve(resolvedCommand: "/bin/claude"),
					   .unresolvable(.canonicalPathUnreadable))
	}

	func testEmptyCanonicalPathIsCanonicalPathFailure() {
		XCTAssertEqual(makeResolver(recorder: CallRecorder(), canonicalPath: "").resolve(resolvedCommand: "/bin/claude"),
					   .unresolvable(.canonicalPathUnreadable))
	}

	// MARK: - Hashing

	func testHashFailureIsUnresolvable() {
		XCTAssertEqual(makeResolver(recorder: CallRecorder(), hash: .some(nil))
			.resolve(resolvedCommand: "/bin/claude"), .unresolvable(.hashUnreadable))
	}

	/// Size comes from the hashing read, not a separate `stat`, so there is no
	/// independent metadata failure to classify.
	func testSizeComesFromTheHashingRead() throws {
		let resolution = makeResolver(recorder: CallRecorder(), hash: (ClaudeSHA256(hex)!, 4242))
			.resolve(resolvedCommand: "/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.sizeBytes, 4242)
		XCTAssertEqual(identity.sha256.value, hex)
	}

	// MARK: - Signing

	/// Codesign failure is NOT an identification failure.
	func testSigningFailureStillResolvesAsUnreadable() throws {
		let resolution = makeResolver(recorder: CallRecorder(), signingClass: .unreadable)
			.resolve(resolvedCommand: "/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.signingClass, .unreadable)
	}

	// MARK: - Symlinks and path classification

	/// Classification must run on the canonical path. A Homebrew shim in
	/// /opt/homebrew/bin pointing into the Cellar must classify from the target.
	func testPathClassIsDerivedAfterSymlinkResolution() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "\("/host/home")/.local/share/claude/versions/2.1.216").resolve(resolvedCommand: "/opt/homebrew/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.resolvedPath, "/opt/homebrew/bin/claude")
		XCTAssertEqual(identity.realPath, "\("/host/home")/.local/share/claude/versions/2.1.216")
		// Classified from the canonical path, NOT the /opt/homebrew shim.
		XCTAssertEqual(identity.pathClass, .userLocal)
	}

	func testClassifiesHomebrewCanonicalPath() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "/opt/homebrew/Cellar/claude/2.1.216/bin/claude").resolve(resolvedCommand: "/opt/homebrew/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .homebrew)
	}

	func testClassifiesNpmGlobalCanonicalPath() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js").resolve(resolvedCommand: "/usr/local/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .npmGlobal)
	}

	func testClassifiesSystemCanonicalPath() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "/usr/bin/claude").resolve(resolvedCommand: "/usr/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .system)
	}

	/// A project-local dependency is NOT a global npm install. Matching any path
	/// containing "/node_modules/" would misreport installation provenance.
	func testProjectLocalNodeModulesIsNotNpmGlobal() throws {
		let resolution = makeResolver(recorder: CallRecorder(),
									  canonicalPath: "/Users/x/project/node_modules/.bin/claude")
			.resolve(resolvedCommand: "/Users/x/project/node_modules/.bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertNotEqual(identity.pathClass, .npmGlobal)
		XCTAssertEqual(identity.pathClass, .unknown)
	}

	/// A Homebrew-installed global npm package is npmGlobal, not homebrew: the
	/// more specific provenance wins.
	func testHomebrewNodeModulesIsNpmGlobal() throws {
		let resolution = makeResolver(
			recorder: CallRecorder(),
			canonicalPath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
		).resolve(resolvedCommand: "/opt/homebrew/bin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .npmGlobal)
	}

	func testClassifiesUsrSbinAsSystem() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "/usr/sbin/claude")
			.resolve(resolvedCommand: "/usr/sbin/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .system)
	}

	func testClassifiesUnknownCanonicalPath() throws {
		let resolution = makeResolver(recorder: CallRecorder(), canonicalPath: "/somewhere/odd/claude").resolve(resolvedCommand: "/somewhere/odd/claude")
		guard case .resolved(let identity) = resolution else { return XCTFail("expected resolved") }
		XCTAssertEqual(identity.pathClass, .unknown)
	}
    func testHomeClassificationUsesOnlyTheInjectedHomeAndKeepsDirectoryBoundaries() {
        let classify = ClaudeRuntimeIdentityResolver.pathClass
        XCTAssertEqual(classify("/host/home/.local/bin/claude", "/host/home"), .userLocal)
        XCTAssertEqual(classify("/different/home/.local/bin/claude", "/host/home"), .unknown)
        XCTAssertEqual(classify("/host/home/.local-other/bin/claude", "/host/home"), .unknown)
        XCTAssertEqual(classify("/host/home/.nvm/versions/claude", "/host/home"), .userLocal)
    }

}
