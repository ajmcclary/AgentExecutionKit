import XCTest
import Darwin
@testable import AgentCodexClient
import ProcessKit
import CodexRuntimeKit

/// Process-transport characterization gate for the CodexAppServerClient
/// process-transport extraction (2026-07-17). Pins the transport-layer
/// behavior that must survive the move into CodexAppServerProcessTransport:
/// genuine-EOF teardown, stale-EOF/stale-write generation scoping, write
/// failures poisoning exactly their own transport, partial reader-setup
/// failure cleanup, idempotent stop, exact-PID registrar cleanup, and a
/// single teardown/reap path even when EOF and stop race.
final class CodexAppServerTransportCharacterizationTests: XCTestCase {

	// MARK: - Harness

	private var fakeServerDir: URL?

	override func tearDown() async throws {
		if let fakeServerDir {
			try? FileManager.default.removeItem(at: fakeServerDir)
		}
		fakeServerDir = nil
		try await super.tearDown()
	}

	/// Writes a minimal Codex app-server stand-in that first records its own
	/// PID to `server.pid` in the script directory, then replies
	/// `{"id":N,"result":{}}` to every request line and ignores notifications.
	private func makeFakeCodexServerScript() throws -> (script: URL, pidFile: URL) {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-fake-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let script = dir.appendingPathComponent("codex")
		let pidFile = dir.appendingPathComponent("server.pid")
		let body = """
		#!/bin/sh
		echo $$ > "\(pidFile.path)"
		while IFS= read -r line; do
		  case "$line" in *model*hang*) continue;; esac
		  id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
		  if [ -n "$id" ]; then
		    printf '{"id":%s,"result":{}}\\n' "$id"
		  fi
		done
		"""
		try body.write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		fakeServerDir = dir
		return (script, pidFile)
	}

	private func makeFakeServerConfig(commandPath: String) -> CodexAppServerClient.Config {
		CodexAppServerClient.Config(
			commandName: commandPath,
			additionalPathHints: [],
			enableDebugLogging: false,
			requestTimeout: nil,
			workingDirectory: FileManager.default.temporaryDirectory.path
		)
	}

	private final class RecordedPIDRegistrarState: @unchecked Sendable {
		private let lock = NSLock()
		private var events: [String] = []

		func append(_ event: String) {
			lock.lock()
			events.append(event)
			lock.unlock()
		}

		func snapshot() -> [String] {
			lock.lock()
			defer { lock.unlock() }
			return events
		}
	}

	private func makeRecordingRegistrar(
		_ state: RecordedPIDRegistrarState
	) -> CodexAppServerClient.ExpectedAgentPIDRegistrar {
		CodexAppServerClient.ExpectedAgentPIDRegistrar(
			register: { pid, clientName, _ in state.append("register:\(pid):\(clientName)") },
			clear: { pid, clientName, _ in state.append("clear:\(pid):\(clientName)") }
		)
	}

	private final class ScriptedLivenessProbeState: @unchecked Sendable {
		private let lock = NSLock()
		private let failingProbeNumbers: Set<Int>
		private var probeCount = 0

		init(failingProbeNumbers: Set<Int>) {
			self.failingProbeNumbers = failingProbeNumbers
		}

		func shouldReportAlive() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			probeCount += 1
			return !failingProbeNumbers.contains(probeCount)
		}
	}

	private final class ToggleState: @unchecked Sendable {
		private let lock = NSLock()
		private var enabled: Bool

		init(enabled: Bool) {
			self.enabled = enabled
		}

		var isEnabled: Bool {
			lock.lock()
			defer { lock.unlock() }
			return enabled
		}

		func set(_ enabled: Bool) {
			lock.lock()
			self.enabled = enabled
			lock.unlock()
		}
	}

	@discardableResult
	private func waitUntil(
		timeout: TimeInterval = 2,
		_ condition: () async -> Bool
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if await condition() { return true }
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return await condition()
	}

	private func processIsGone(_ pid: pid_t) -> Bool {
		Darwin.kill(pid, 0) == -1 && errno == ESRCH
	}

	// MARK: - Genuine stdout EOF

	func testStdoutEOFTerminatesTransportAndFailsPendingRequests() async throws {
		let (script, _) = try makeFakeCodexServerScript()
		let client = CodexAppServerClient()
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))
		try await client.startIfNeeded()
		let pidValue = await client.debugProcessID()
		let pid = try XCTUnwrap(pidValue)

		// Only the thrown error is asserted below, so the (non-`Sendable`)
		// dictionary is discarded inside the task — `Task.Success` must be
		// `Sendable` and `request` returns `sending [String: Any]`.
		let requestTask = Task { () async throws -> Void in
			// Hang-proofing only: the fake server never answers model/hang, and
			// the EOF teardown must fail this request long before the timeout.
			_ = try await client.request(method: "model/hang", params: nil, timeout: 10)
		}
		let registered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(registered)

		XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)

		let terminated = await waitUntil { await client.debugIsProcessRunning() == false }
		XCTAssertTrue(terminated, "Genuine stdout EOF must tear down the transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .stdoutEOF)

		do {
			_ = try await requestTask.value
			XCTFail("Pending request must fail when EOF tears down the transport")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .processNotRunning = error else {
				return XCTFail("Expected processNotRunning, got \(error)")
			}
		}
		await client.stop()
	}

	// MARK: - Stale-EOF generation scoping

	func testStaleEOFFromReplacedTransportDoesNotTearDownNewTransport() async throws {
		let (script, _) = try makeFakeCodexServerScript()
		let probeState = ScriptedLivenessProbeState(failingProbeNumbers: [1])
		let client = CodexAppServerClient(livenessProbe: { _ in probeState.shouldReportAlive() })
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))

		try await client.startIfNeeded()
		let firstGeneration = await client.debugTransportGeneration()

		// Liveness failure kills the first transport and starts a replacement.
		// The first process's stdout EOF arrives while generation 2 is live.
		try await client.startIfNeeded()
		let secondGeneration = await client.debugTransportGeneration()
		XCTAssertEqual(secondGeneration, firstGeneration + 1)

		try? await Task.sleep(nanoseconds: 300_000_000)
		let stillRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(stillRunning, "Stale EOF from the replaced transport must not kill the new one")
		let generationAfter = await client.debugTransportGeneration()
		XCTAssertEqual(generationAfter, secondGeneration, "No further teardown/restart may occur")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(
			reason,
			.livenessCheckFailed(method: nil),
			"Termination reason must stay pinned to the liveness teardown, not a stale stdoutEOF"
		)
		await client.stop()
	}

	// MARK: - Stdin write failures

	func testStdinWriteFailurePoisonsOnlyItsOwnTransport() async throws {
		let failWrites = ToggleState(enabled: true)
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in
			if failWrites.isEnabled {
				throw FDWriteError.brokenPipe(errno: EPIPE)
			}
		})
		await client.debugInstallTestTransport()

		do {
			_ = try await client.request(method: "model/list", params: nil)
			XCTFail("Expected transportWriteFailed")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .transportWriteFailed(_, let errnoValue) = error else {
				return XCTFail("Expected transportWriteFailed, got \(error)")
			}
			XCTAssertEqual(errnoValue, EPIPE)
		}

		let terminated = await waitUntil { await client.debugIsProcessRunning() == false }
		XCTAssertTrue(terminated, "A stdin write failure must tear down its transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .stdinWrite(method: "model/list", errno: EPIPE))
		let pending = await client.debugPendingRequestCount()
		XCTAssertEqual(pending, 0, "The failed request must not stay pending")

		// A replacement transport (next generation) must be unaffected by any
		// cleanup still queued from the failed generation.
		failWrites.set(false)
		await client.debugInstallTestTransport()
		// The request store's ID counter persists across transports: the failed
		// request consumed id 1, so this one is id 2.
		let nextID = await client.debugNextRequestID()
		// `request` returns `sending [String: Any]`, but `Task.Success` must be
		// `Sendable`, so the asserted field is projected to a `Sendable` value
		// inside the task rather than carrying the dictionary across.
		let requestTask = Task { () async throws -> Bool? in
			try await client.request(method: "model/list", params: nil, timeout: 10)["ok"] as? Bool
		}
		let registered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(registered)
		await client.debugIngestRawStdoutLine(Data(#"{"id":\#(nextID),"result":{"ok":true}}"#.utf8))
		let ok = try await requestTask.value
		XCTAssertEqual(ok, true)
		try? await Task.sleep(nanoseconds: 200_000_000)
		let stillRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(stillRunning, "Stale write-failure cleanup must not kill the replacement transport")
		await client.stop()
	}

	// MARK: - Partial reader setup failure

	func testPartialReaderSetupFailureCleansUpSpawnedProcessAndAllowsRestart() async throws {
		let (script, pidFile) = try makeFakeCodexServerScript()
		let failStderrPreflight = ToggleState(enabled: true)
		let client = CodexAppServerClient(readPreflight: { fd, label in
			if failStderrPreflight.isEnabled, label.contains("stderr") {
				throw POSIXError(.EBADF)
			}
			try CodexTestHost.validateFD(fd, label: label)
		})
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))

		do {
			try await client.startIfNeeded()
			XCTFail("Expected transportReadSetupFailed")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .transportReadSetupFailed(_, let errnoValue) = error else {
				return XCTFail("Expected transportReadSetupFailed, got \(error)")
			}
			XCTAssertEqual(errnoValue, EBADF)
		}

		let running = await client.debugIsProcessRunning()
		XCTAssertFalse(running, "A partial reader setup failure must not leave a half-wired transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .readSourceSetupFailed(stream: "process pipe", errno: EBADF))

		let pidText = try String(contentsOf: pidFile, encoding: .utf8)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let spawnedPID = try XCTUnwrap(pid_t(pidText))
		let reaped = await waitUntil { self.processIsGone(spawnedPID) }
		XCTAssertTrue(reaped, "The spawned process must be terminated and reaped after setup failure")

		// The failure path must leave the client restartable.
		failStderrPreflight.set(false)
		try await client.startIfNeeded()
		let restartedRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(restartedRunning)
		await client.stop()
	}

	// MARK: - Idempotent stop + exact PID registrar cleanup

	func testStopIsIdempotentAndClearsPIDRegistrationExactlyOnce() async throws {
		let state = RecordedPIDRegistrarState()
		let client = CodexAppServerClient(expectedAgentPIDRegistrar: makeRecordingRegistrar(state))
		await client.debugInstallTestTransport()
		let pidValue = await client.debugProcessID()
		let pid = try XCTUnwrap(pidValue)
		await client.setExpectedAgentPIDRegistration(.init(clientName: "alpha", runID: UUID()))

		await client.stop()
		await client.stop()

		XCTAssertEqual(
			state.snapshot(),
			["register:\(pid):alpha", "clear:\(pid):alpha"],
			"A second stop must not re-run teardown or re-clear the PID registration"
		)
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .explicitStop)
	}

	func testStopKillsAndReapsSpawnedProcess() async throws {
		let (script, _) = try makeFakeCodexServerScript()
		let client = CodexAppServerClient()
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))
		try await client.startIfNeeded()
		let pidValue = await client.debugProcessID()
		let pid = try XCTUnwrap(pidValue)
		XCTAssertEqual(Darwin.kill(pid, 0), 0, "Sanity: server process is alive before stop")

		await client.stop()

		let gone = await waitUntil { self.processIsGone(pid) }
		XCTAssertTrue(gone, "Stop must terminate AND reap the exact spawned PID (no zombie left)")
	}

	// MARK: - Single teardown path when EOF and stop race

	func testEOFTeardownFollowedByStopRunsSingleTeardown() async throws {
		let (script, _) = try makeFakeCodexServerScript()
		let state = RecordedPIDRegistrarState()
		let client = CodexAppServerClient(expectedAgentPIDRegistrar: makeRecordingRegistrar(state))
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))
		try await client.startIfNeeded()
		let pidValue = await client.debugProcessID()
		let pid = try XCTUnwrap(pidValue)
		await client.setExpectedAgentPIDRegistration(.init(clientName: "alpha", runID: UUID()))

		XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
		let terminated = await waitUntil { await client.debugIsProcessRunning() == false }
		XCTAssertTrue(terminated)

		await client.stop()

		XCTAssertEqual(
			state.snapshot(),
			["register:\(pid):alpha", "clear:\(pid):alpha"],
			"EOF teardown followed by stop must clear the PID registration exactly once"
		)
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .stdoutEOF, "stop after EOF teardown must be a no-op, preserving the first reason")
		let gone = await waitUntil { self.processIsGone(pid) }
		XCTAssertTrue(gone, "The killed server must be reaped by the single teardown path")
	}
}
