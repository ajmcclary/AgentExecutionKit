import XCTest
import Darwin
@testable import AgentCodexClient
import ProcessKit
import CodexRuntimeKit

/// Deterministic client-runtime characterization gate for the
/// CodexAppServerClient decomposition (2026-07-17). Pins single-flight
/// startup, generation isolation, continuation single-resume, timeout
/// poisoning, decode-recovery budgets, PID registration lifecycle, and
/// subscriber-stream completion — all without a real `codex` binary.
final class CodexAppServerClientRuntimeCharacterizationTests: XCTestCase {

	// MARK: - Harness

	private var fakeServerDir: URL?

	override func tearDown() async throws {
		if let fakeServerDir {
			try? FileManager.default.removeItem(at: fakeServerDir)
		}
		fakeServerDir = nil
		try await super.tearDown()
	}

	/// Writes a minimal Codex app-server stand-in: replies `{"id":N,"result":{}}`
	/// to every request line and ignores notifications.
	private func makeFakeCodexServerScript() throws -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("codex-fake-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let script = dir.appendingPathComponent("codex")
		let body = #"""
		#!/bin/sh
		while IFS= read -r line; do
		  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
		  if [ -n "$id" ]; then
		    printf '{"id":%s,"result":{}}\n' "$id"
		  fi
		done
		"""#
		try body.write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		fakeServerDir = dir
		return script
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

	/// Reads up to `count` notification methods with a hard deadline so a
	/// missing broadcast fails the test instead of hanging the suite.
	private func collectNotificationMethods(
		from stream: AsyncStream<CodexAppServerClient.Notification>,
		count: Int,
		timeout: TimeInterval = 5
	) async -> [String] {
		await withTaskGroup(of: [String].self) { group in
			group.addTask {
				var methods: [String] = []
				for await notification in stream {
					methods.append(notification.method)
					if methods.count == count { break }
				}
				return methods
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
				return []
			}
			let winner = await group.next() ?? []
			group.cancelAll()
			return winner
		}
	}

	// MARK: - Single-flight startup

	func testConcurrentStartIfNeededPerformsSingleInitialize() async throws {
		let script = try makeFakeCodexServerScript()
		let client = CodexAppServerClient()
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))

		try await withThrowingTaskGroup(of: Void.self) { group in
			for _ in 0..<4 {
				group.addTask { try await client.startIfNeeded() }
			}
			try await group.waitForAll()
		}

		let nextRequestID = await client.debugNextRequestID()
		XCTAssertEqual(nextRequestID, 2, "Concurrent startup must coalesce to exactly one initialize request")
		let pid = await client.debugProcessID()
		XCTAssertNotNil(pid)
		await client.stop()
	}

	func testStartupFailureIsSharedAcrossConcurrentCallersAndCleared() async throws {
		let missing = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
			.appendingPathComponent("codex")
		let client = CodexAppServerClient()
		await client.updateConfig(makeFakeServerConfig(commandPath: missing.path))

		await withTaskGroup(of: Bool.self) { group in
			for _ in 0..<3 {
				group.addTask {
					do {
						try await client.startIfNeeded()
						return false
					} catch let error as CodexAppServerClient.ClientError {
						if case .executableUnavailable = error { return true }
						return false
					} catch {
						return false
					}
				}
			}
			for await sawExpectedError in group {
				XCTAssertTrue(sawExpectedError, "Every concurrent caller shares the executable-unavailable failure")
			}
		}

		do {
			try await client.startIfNeeded()
			XCTFail("Startup task must be cleared after failure so retries re-run startup")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .executableUnavailable = error else {
				return XCTFail("Expected executable-unavailable on retry, got \(error)")
			}
		}
	}

	// MARK: - Generation isolation

	func testLivenessFailureRestartAdvancesGenerationAndReplacesPID() async throws {
		let script = try makeFakeCodexServerScript()
		let probeState = ScriptedLivenessProbeState(failingProbeNumbers: [1])
		let client = CodexAppServerClient(livenessProbe: { _ in probeState.shouldReportAlive() })
		await client.updateConfig(makeFakeServerConfig(commandPath: script.path))

		try await client.startIfNeeded()
		let firstPIDValue = await client.debugProcessID()
		let firstPID = try XCTUnwrap(firstPIDValue)
		let firstGeneration = await client.debugTransportGeneration()

		try await client.startIfNeeded()
		let secondPIDValue = await client.debugProcessID()
		let secondPID = try XCTUnwrap(secondPIDValue)
		let secondGeneration = await client.debugTransportGeneration()

		XCTAssertNotEqual(firstPID, secondPID, "Stale transport must be replaced")
		XCTAssertEqual(secondGeneration, firstGeneration + 1, "Restart must advance the transport generation")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .livenessCheckFailed(method: nil))
		await client.stop()
	}

	// MARK: - Continuation single-resume

	func testResponseForSameRequestIDResolvesExactlyOnce() async throws {
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in })
		await client.debugInstallTestTransport()

		// `request` returns `sending [String: Any]`, but `Task.Success` must be
		// `Sendable`, so the asserted field is projected to a `Sendable` value
		// inside the task rather than carrying the dictionary across.
		let requestTask = Task { () async throws -> String? in
			try await client.request(method: "model/list", params: nil)["winner"] as? String
		}
		let registered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(registered, "Request must be pending before responses are ingested")

		await client.debugIngestRawStdoutLine(Data(#"{"id":1,"result":{"winner":"first"}}"#.utf8))
		await client.debugIngestRawStdoutLine(Data(#"{"id":1,"result":{"winner":"second"}}"#.utf8))
		await client.debugIngestRawStdoutLine(Data(#"{"id":1,"error":{"code":-1,"message":"late error"}}"#.utf8))

		let winner = try await requestTask.value
		XCTAssertEqual(winner, "first", "First resolution wins; duplicates are dropped")
		let pendingAfter = await client.debugPendingRequestCount()
		XCTAssertEqual(pendingAfter, 0)
		let stillRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(stillRunning, "Late duplicate responses must not poison the transport")
		await client.stop()
	}

	// MARK: - Timeout poisoning

	func testThreadStartTimeoutPoisonsTransport() async throws {
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in })
		await client.debugInstallTestTransport()

		do {
			_ = try await client.request(method: "thread/start", params: [:], timeout: 0.05)
			XCTFail("Expected thread/start timeout")
		} catch {
			XCTAssertTrue(
				error.localizedDescription.contains("Request timed out after"),
				"Expected timeout error, got: \(error.localizedDescription)"
			)
		}

		let terminated = await waitUntil { await client.debugIsProcessRunning() == false }
		XCTAssertTrue(terminated, "thread/start timeout must poison the transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .timeout(method: "thread/start", requestID: "1"))
		await client.stop()
	}

	func testNonCriticalMethodTimeoutDoesNotPoisonTransport() async throws {
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in })
		await client.debugInstallTestTransport()

		do {
			_ = try await client.request(method: "model/list", params: nil, timeout: 0.05)
			XCTFail("Expected model/list timeout")
		} catch {
			XCTAssertTrue(error.localizedDescription.contains("Request timed out after"))
		}

		try? await Task.sleep(nanoseconds: 150_000_000)
		let stillRunning = await client.debugIsProcessRunning()
		XCTAssertTrue(stillRunning, "Non-critical timeouts must not poison the transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertNil(reason)
		let pending = await client.debugPendingRequestCount()
		XCTAssertEqual(pending, 0)
		let timeouts = await client.debugTimeoutTaskCount()
		XCTAssertEqual(timeouts, 0)
		await client.stop()
	}

	// MARK: - Decode-recovery budget

	func testDecodeRecoveryBudgetExhaustionTerminatesTransport() async throws {
		let client = CodexAppServerClient()
		await client.debugInstallTestTransport()
		let generation = await client.debugTransportGeneration()

		let malformed = Data(#"{"jsonrpc":"2.0","method":"turn/completed""#.utf8)
		let maxAttempts = CodexAppServerClient.debugMaxDecodeRecoveryAttemptsPerGeneration()
		for _ in 0..<maxAttempts {
			await client.debugIngestRawStdoutLine(malformed)
		}
		let aliveAtBoundary = await client.debugIsProcessRunning()
		XCTAssertTrue(aliveAtBoundary, "Transport survives until the budget is actually exhausted")

		await client.debugIngestRawStdoutLine(malformed)
		let terminated = await waitUntil { await client.debugIsProcessRunning() == false }
		XCTAssertTrue(terminated, "Budget exhaustion must terminate the poisoned transport")
		let reason = await client.debugLastTransportTerminationReason()
		XCTAssertEqual(reason, .decodeRecoveryBudgetExceeded(generation: generation))
		await client.stop()
	}

	func testSuccessfulDecodeResetsRecoveryBudget() async throws {
		let client = CodexAppServerClient()
		await client.debugInstallTestTransport()

		let malformed = Data(#"{"broken"#.utf8)
		for _ in 0..<3 {
			await client.debugIngestRawStdoutLine(malformed)
		}
		let attemptsBefore = await client.debugDecodeRecoveryAttempts()
		XCTAssertEqual(attemptsBefore, 3)

		await client.debugIngestRawStdoutLine(Data(#"{"method":"noop/evt","params":{}}"#.utf8))
		let attemptsAfter = await client.debugDecodeRecoveryAttempts()
		XCTAssertEqual(attemptsAfter, 0, "A successful decode resets the recovery budget")
		await client.stop()
	}

	// MARK: - Recovery heuristics (observable through notification routing)

	func testConcatenatedObjectsOnOneLineAllRoute() async throws {
		let client = CodexAppServerClient()
		let stream = await client.subscribeNotifications()
		await client.debugInstallTestTransport()

		let line = #"{"method":"first/evt","params":{}}{"method":"second/evt","params":{}}"#
		await client.debugIngestRawStdoutLine(Data(line.utf8))

		let methods = await collectNotificationMethods(from: stream, count: 2)
		XCTAssertEqual(methods, ["first/evt", "second/evt"])
		await client.stop()
	}

	func testEmbeddedJSONTailRecovers() async throws {
		let client = CodexAppServerClient()
		let stream = await client.subscribeNotifications()
		await client.debugInstallTestTransport()

		let line = "garbage-prefix-\u{1B}[0m{\"method\":\"tail/evt\",\"params\":{}}"
		await client.debugIngestRawStdoutLine(Data(line.utf8))

		let methods = await collectNotificationMethods(from: stream, count: 1)
		XCTAssertEqual(methods, ["tail/evt"])
		await client.stop()
	}

	func testControlCharacterInsideStringRepairs() async throws {
		let client = CodexAppServerClient()
		let stream = await client.subscribeNotifications()
		await client.debugInstallTestTransport()

		// A raw LF inside a JSON string: the documented repair case (the repair
		// helper only engages when the payload contains an unescaped LF/CR).
		var line = Data(#"{"method":"ctl/evt","params":{"text":"a"#.utf8)
		line.append(0x0A)
		line.append(contentsOf: Data(#"b"}}"#.utf8))
		await client.debugIngestRawStdoutLine(line)

		let methods = await collectNotificationMethods(from: stream, count: 1)
		XCTAssertEqual(methods, ["ctl/evt"])
		await client.stop()
	}

	// MARK: - Stream completion + pending-request failure on stop

	func testStopFinishesSubscriberStreamsAndFailsPendingRequests() async throws {
		let client = CodexAppServerClient(writeFrameHandler: { _, _ in })
		let notifications = await client.subscribeNotifications()
		let serverRequests = await client.subscribeServerRequests()
		await client.debugInstallTestTransport()

		// Only the thrown error is asserted below, so the (non-`Sendable`)
		// dictionary is discarded inside the task — `Task.Success` must be
		// `Sendable` and `request` returns `sending [String: Any]`.
		let requestTask = Task { () async throws -> Void in
			_ = try await client.request(method: "model/list", params: nil)
		}
		let registered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(registered)

		await client.stop()

		do {
			_ = try await requestTask.value
			XCTFail("Pending request must fail when the transport stops")
		} catch let error as CodexAppServerClient.ClientError {
			guard case .processNotRunning = error else {
				return XCTFail("Expected processNotRunning, got \(error)")
			}
		}

		var notificationCount = 0
		for await _ in notifications { notificationCount += 1 }
		var serverRequestCount = 0
		for await _ in serverRequests { serverRequestCount += 1 }
		XCTAssertEqual(notificationCount, 0, "Notification stream must finish on stop")
		XCTAssertEqual(serverRequestCount, 0, "Server-request stream must finish on stop")
	}

	// MARK: - PID registration lifecycle

	func testReplacingPIDRegistrationClearsOldAndRegistersNew() async throws {
		let state = RecordedPIDRegistrarState()
		let registrar = CodexAppServerClient.ExpectedAgentPIDRegistrar(
			register: { pid, clientName, _ in state.append("register:\(pid):\(clientName)") },
			clear: { pid, clientName, _ in state.append("clear:\(pid):\(clientName)") }
		)
		let client = CodexAppServerClient(expectedAgentPIDRegistrar: registrar)
		await client.debugInstallTestTransport()
		let pidValue = await client.debugProcessID()
		let pid = try XCTUnwrap(pidValue)

		await client.setExpectedAgentPIDRegistration(
			.init(clientName: "alpha", runID: UUID())
		)
		await client.setExpectedAgentPIDRegistration(
			.init(clientName: "beta", runID: UUID())
		)
		await client.stop()

		XCTAssertEqual(
			state.snapshot(),
			[
				"register:\(pid):alpha",
				"clear:\(pid):alpha",
				"register:\(pid):beta",
				"clear:\(pid):beta"
			],
			"Replacing a registration clears the old one; stop clears the active one"
		)
	}
}
