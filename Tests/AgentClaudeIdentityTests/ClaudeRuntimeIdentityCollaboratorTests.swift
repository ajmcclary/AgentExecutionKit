import XCTest
@testable import AgentClaudeIdentity
import AIClientStorage
import AgentProcessSupport

/// Live adapters for the identity resolver. These touch the real filesystem and
/// Security.framework, against fixtures created in a temp directory.
final class ClaudeRuntimeIdentityCollaboratorTests: XCTestCase {

	private var tempDir: URL!

	override func setUpWithError() throws {
		tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("claude-identity-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: tempDir)
	}

	// MARK: - Hashing

	/// Known-answer test: SHA-256("abc") is a published constant, so this pins the
	/// digest itself rather than merely "some 64 hex characters".
	func testHashesKnownContentToKnownDigest() throws {
		let file = tempDir.appendingPathComponent("abc.bin")
		try Data("abc".utf8).write(to: file)

		let result = try XCTUnwrap(ClaudeExecutableHasher().hashAndSize(atCanonicalPath: file.path))
		XCTAssertEqual(result.sha256.value,
					   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
		XCTAssertEqual(result.sizeBytes, 3)
	}

	/// Size and digest must agree across chunk boundaries — a chunked read that
	/// dropped or double-counted a chunk would still produce 64 hex characters.
	func testHashesAcrossChunkBoundaries() throws {
		let file = tempDir.appendingPathComponent("chunked.bin")
		let payload = Data(repeating: 0x41, count: 300_000)
		try payload.write(to: file)

		let small = try XCTUnwrap(
			ClaudeExecutableHasher(chunkSize: 4096).hashAndSize(atCanonicalPath: file.path))
		let large = try XCTUnwrap(
			ClaudeExecutableHasher(chunkSize: 1 << 20).hashAndSize(atCanonicalPath: file.path))

		XCTAssertEqual(small.sizeBytes, 300_000)
		XCTAssertEqual(small.sha256, large.sha256)
	}

	func testHashesEmptyFile() throws {
		let file = tempDir.appendingPathComponent("empty.bin")
		try Data().write(to: file)
		let result = try XCTUnwrap(ClaudeExecutableHasher().hashAndSize(atCanonicalPath: file.path))
		XCTAssertEqual(result.sizeBytes, 0)
		XCTAssertEqual(result.sha256.value,
					   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	}

	/// A non-positive chunk size must not silently hash a non-empty file as empty:
	/// `read(upToCount: 0)` returns empty immediately, ending the loop on the first
	/// iteration and producing the empty digest with size 0.
	func testNonPositiveChunkSizeStillHashesCorrectly() throws {
		let file = tempDir.appendingPathComponent("abc.bin")
		try Data("abc".utf8).write(to: file)
		let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

		for chunkSize in [0, -1] {
			let result = try XCTUnwrap(
				ClaudeExecutableHasher(chunkSize: chunkSize).hashAndSize(atCanonicalPath: file.path),
				"chunkSize \(chunkSize)")
			XCTAssertEqual(result.sha256.value, expected, "chunkSize \(chunkSize)")
			XCTAssertEqual(result.sizeBytes, 3, "chunkSize \(chunkSize)")
		}
	}

	func testHashOfMissingFileFails() {
		let missing = tempDir.appendingPathComponent("nope.bin").path
		XCTAssertNil(ClaudeExecutableHasher().hashAndSize(atCanonicalPath: missing))
	}

	// MARK: - Canonicalization

	func testCanonicalPathFollowsSymlink() throws {
		let target = tempDir.appendingPathComponent("target.bin")
		try Data("x".utf8).write(to: target)
		let link = tempDir.appendingPathComponent("link.bin")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

		let canonical = try XCTUnwrap(
			ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).canonicalPath(ofResolvedCommand: link.path))
		XCTAssertTrue(canonical.hasSuffix("target.bin"), "got \(canonical)")
		XCTAssertFalse(canonical.hasSuffix("link.bin"))
	}

	/// A broken chain must fail rather than echo its input back — the reason
	/// `realpath` is used instead of `resolvingSymlinksInPath()`.
	func testCanonicalPathOfBrokenSymlinkFails() throws {
		let link = tempDir.appendingPathComponent("broken.bin")
		try FileManager.default.createSymbolicLink(
			at: link, withDestinationURL: tempDir.appendingPathComponent("absent.bin"))
		XCTAssertNil(ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).canonicalPath(ofResolvedCommand: link.path))
	}

	func testCanonicalPathOfMissingPathFails() {
		let missing = tempDir.appendingPathComponent("nope").path
		XCTAssertNil(ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).canonicalPath(ofResolvedCommand: missing))
	}

	// MARK: - Launchability passthrough

	func testLaunchabilityReportsNonExecutableFile() throws {
		let file = tempDir.appendingPathComponent("plain.txt")
		try Data("x".utf8).write(to: file)
		XCTAssertEqual(
			ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).launchability(ofResolvedCommand: file.path),
			.notExecutable)
	}

	func testLaunchabilityReportsDirectory() {
		XCTAssertEqual(
			ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).launchability(ofResolvedCommand: tempDir.path),
			.directory)
	}

	func testLaunchabilityReportsBareCommandFallback() {
		XCTAssertEqual(
			ClaudeExecutableFileSystemProbe(launchability: fixtureLaunchability).launchability(ofResolvedCommand: "claude"),
			.bareCommandFallback)
	}

	// MARK: - Signing

	/// Exact assertion: accepting `[.unsigned, .unreadable]` would pass even if
	/// signing inspection were broken entirely.
	func testSigningOfUnsignedFileIsUnsigned() throws {
		let file = tempDir.appendingPathComponent("unsigned.bin")
		try Data("x".utf8).write(to: file)
		XCTAssertEqual(
			ClaudeExecutableSigningInspector(validateTeamIdentifier: { AIStorageRuntimePolicy.isValidAppleTeamIdentifier($0) }).signingClass(atCanonicalPath: file.path),
			.unsigned)
	}

	func testSigningOfMissingPathIsUnreadable() {
		let missing = tempDir.appendingPathComponent("nope").path
		XCTAssertEqual(
			ClaudeExecutableSigningInspector(validateTeamIdentifier: { AIStorageRuntimePolicy.isValidAppleTeamIdentifier($0) }).signingClass(atCanonicalPath: missing),
			.unreadable)
	}

	/// `/bin/ls` is Apple **platform**-signed: no team identifier, Authority
	/// "macOS Software Signing". Calling that `.unsigned` would be false telemetry,
	/// and calling it `.appleDeveloperID` would conflate trust classes.
	func testSigningOfPlatformBinaryIsApplePlatform() {
		XCTAssertEqual(
			ClaudeExecutableSigningInspector(validateTeamIdentifier: { AIStorageRuntimePolicy.isValidAppleTeamIdentifier($0) }).signingClass(atCanonicalPath: "/bin/ls"),
			.applePlatform)
	}

	/// Ad-hoc signs a copy of `/bin/ls`, optionally flipping a byte afterwards.
	/// Needs no credentials — `codesign --sign -` is an ad-hoc identity.
	private func makeAdHocSignedCopy(tamperedAtOffset offset: Int? = nil) throws -> String {
		let copy = tempDir.appendingPathComponent(offset == nil ? "adhoc.bin" : "adhoc-tampered.bin")
		try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
		// The copy inherits r-xr-xr-x; codesign needs to write to it.
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
		process.arguments = ["--force", "--sign", "-", copy.path]
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		try process.run()
		process.waitUntilExit()
		try XCTSkipUnless(process.terminationStatus == 0, "codesign unavailable")

		if let offset {
			var bytes = try Data(contentsOf: copy)
			try XCTSkipUnless(bytes.count > offset, "fixture smaller than tamper offset")
			bytes[offset] ^= 0xFF
			try bytes.write(to: copy)
		}
		return copy.path
	}

	func testValidAdHocBinaryIsAdHoc() throws {
		let path = try makeAdHocSignedCopy()
		XCTAssertEqual(
			ClaudeExecutableSigningInspector(validateTeamIdentifier: { AIStorageRuntimePolicy.isValidAppleTeamIdentifier($0) }).signingClass(atCanonicalPath: path),
			.adHoc)
	}

	/// Integrity must be checked BEFORE the ad-hoc flag. A nil-requirement strict
	/// validation verifies integrity rather than anchor, so it accepts an intact
	/// ad-hoc signature — meaning a tampered binary whose ad-hoc metadata is still
	/// readable would be reported `.adHoc` if the flag were consulted first.
	func testTamperedAdHocBinaryIsInvalid() throws {
		let path = try makeAdHocSignedCopy(tamperedAtOffset: 32768)
		XCTAssertEqual(
			ClaudeExecutableSigningInspector(validateTeamIdentifier: { AIStorageRuntimePolicy.isValidAppleTeamIdentifier($0) }).signingClass(atCanonicalPath: path),
			.invalid)
	}

}

private func fixtureLaunchability(_ command: String) -> AgentExecutableLaunchability {
    if !command.contains("/") { return .bareCommandFallback }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: command, isDirectory: &isDirectory) else { return .missingPath }
    if isDirectory.boolValue { return .directory }
    return FileManager.default.isExecutableFile(atPath: command) ? .launchable : .notExecutable
}
