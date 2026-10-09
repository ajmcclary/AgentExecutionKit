import XCTest
import Foundation
import Darwin
import Synchronization
import AgentCLIExecution
import ProcessKit

final class AgentCLIExecutionTests: XCTestCase {
	private actor PreparationGate {
		var entered = false
		var continuation: CheckedContinuation<Void, Never>?
		func suspend() async { if entered { return }; entered = true; await withCheckedContinuation { continuation = $0 } }
		func release() { continuation?.resume(); continuation = nil }
	}
	private final class Events: Sendable {
		let items = Mutex<[String]>([])
		func append(_ value: String) { items.withLock { $0.append(value) } }
		func snapshot() -> [String] { items.withLock { $0 } }
	}
	private final class Logs: AgentCLILogSink {
		let events = Events()
		func append(_ value: String) { events.append(value) }
		func appendSection(title: String, content: String) { events.append(title + ":" + content) }
		func appendDataSection(title: String, data: Data) { events.append(title + ":" + String(decoding: data, as: UTF8.self)) }
	}
	private func host(events: Events = Events(), failRead: Bool = false) -> AgentCLIRunner.HostServices {
		.init(environment: { config, extra, removed in
			var values = config.environment.merging(extra) { _, new in new }
			for key in removed { values[key] = nil }
			return values
		}, resolveCommand: { config, _ in config.command }, expandWorkingDirectory: { path, _ in path },
		rememberSuccessfulCommand: { _, _ in },
		terminationPolicy: { .init(cooperativeWaitTimeout: .milliseconds(100), sigtermGracePeriod: .milliseconds(100), sigkillGracePeriod: .milliseconds(100)) },
		diagnostics: { _ in }, readPreflight: { fd, _ in
			if failRead { throw POSIXError(.EBADF) }
			guard fd >= 0, fcntl(fd, F_GETFD) != -1 else { throw POSIXError(.EBADF) }
		}, didStart: { id, _ in events.append("start:" + id.uuidString) }, didFinish: { id, _ in events.append("finish:" + id.uuidString) })
	}
	private func runner(command: String = "/bin/sh", events: Events = Events(), logs: Logs? = nil, failRead: Bool = false) -> AgentCLIRunner {
		AgentCLIRunner(config: .init(command: command, workingDirectory: "/tmp", additionalPaths: [], logCollector: logs), host: host(events: events, failRead: failRead))
	}
	private func waitUntil(_ check: () async -> Bool) async -> Bool {
		for _ in 0..<300 { if await check() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
		return false
	}

	func testBufferedOutputAndStdinAreFullyDrainedAcrossLargeConcurrentPipes() async throws {
		let cli = runner()
		let input = String(repeating: "input-λ\n", count: 30_000)
		let result = try await cli.run(args: ["-c", "/bin/cat; /usr/bin/printf 'stderr-end' >&2"], stdin: input, outputMode: .none, timeout: 5)
		XCTAssertEqual(result.stdout, Data(input.utf8))
		XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "stderr-end")
		XCTAssertEqual(result.status, 0)
	}

	func testStreamingDeliversEveryChunkBeforeExactlyOneTerminationAndCleanup() async throws {
		let events = Events(); let cli = runner(events: events)
		let stream = try await cli.runStreaming(args: ["-c", "i=0; while [ $i -lt 1000 ]; do /usr/bin/printf 'value\n'; i=$((i+1)); done; /usr/bin/printf 'error' >&2"], stdin: nil, outputMode: .none, timeout: 10)
		var output = Data(); var errors = Data(); var ended = 0
		for try await event in stream {
			switch event {
			case .stdout(let chunk): XCTAssertEqual(ended, 0); output.append(chunk)
			case .stderr(let chunk): XCTAssertEqual(ended, 0); errors.append(chunk)
			case .terminated(let status, let timedOut): ended += 1; XCTAssertEqual(status, 0); XCTAssertFalse(timedOut)
			}
		}
		XCTAssertEqual(output, Data(String(repeating: "value\n", count: 1000).utf8))
		XCTAssertEqual(errors, Data("error".utf8)); XCTAssertEqual(ended, 1)
		XCTAssertEqual(events.snapshot().count, 2)
		XCTAssertEqual(events.snapshot()[0].dropFirst(6), events.snapshot()[1].dropFirst(7))
	}

	func testBufferedCancellationCleansUpAndReleasesPermitBeforeThrowing() async throws {
		let events = Events(); let cli = runner(events: events)
		let task = Task { try await cli.run(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil) }
		let started = await waitUntil { events.snapshot().count == 1 }; XCTAssertTrue(started)
		task.cancel()
		do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
		XCTAssertEqual(events.snapshot().count, 2)
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.stdout, Data("next".utf8))
	}

	func testQueuedCancellationNeverLaunchesAndDoesNotStealAnotherPermit() async throws {
		let events = Events(); let cli = runner(events: events)
		let first = Task { try await cli.run(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil) }
		let started = await waitUntil { events.snapshot().count == 1 }; XCTAssertTrue(started)
		let queued = Task { try await cli.run(args: ["-c", "printf unexpected"], stdin: nil, outputMode: .none, timeout: 2) }
		try await Task.sleep(for: .milliseconds(50)); queued.cancel()
		do { _ = try await queued.value; XCTFail("Queued task must cancel") } catch is CancellationError {}
		XCTAssertEqual(events.snapshot().count, 1)
		first.cancel(); _ = try? await first.value
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.status, 0)
		XCTAssertEqual(events.snapshot().filter { $0.hasPrefix("start:") }.count, 2)
	}

	func testCancelAllAndConsumerCancellationShareTheSameCleanupOwner() async throws {
		let events = Events(); let cli = runner(events: events)
		let stream = try await cli.runStreaming(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil)
		let consumer = Task { for try await _ in stream {} }
		consumer.cancel()
		await cli.cancelAll()
		_ = try? await consumer.value
		XCTAssertEqual(events.snapshot().count, 2)
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.status, 0)
	}

	func testTimeoutProducesTerminalStatusWithoutLosingOutput() async throws {
		let cli = runner()
		let result = try await cli.run(args: ["-c", "printf before; exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: 0.15)
		XCTAssertTrue(result.timedOut); XCTAssertNotEqual(result.status, 0)
		XCTAssertEqual(result.stdout, Data("before".utf8))
	}

	func testReadSetupFailureCleansUpChildAndAllowsAnotherLaunch() async throws {
		let events = Events(); let cli = runner(events: events, failRead: true)
		for _ in 0..<2 {
			do { _ = try await cli.run(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil); XCTFail("Expected preflight failure") }
			catch let error as POSIXError { XCTAssertEqual(error.code, .EBADF) }
		}
		XCTAssertEqual(events.snapshot().count, 4)
	}

	func testSpawnFailureAndDirectoryRejectionDoNotLeakPermits() async throws {
		for command in ["/no/fixture/executable", "/tmp"] {
			let cli = runner(command: command)
			for _ in 0..<2 {
				do { _ = try await cli.run(args: [], stdin: nil, outputMode: .none, timeout: 1); XCTFail("Expected launch failure") }
				catch let error as AgentCLIExecutionError { guard case .commandNotFound = error else { return XCTFail("Wrong error: \(error)") } }
			}
		}
	}

	func testEarlyChildExitWhileWritingLargeInputDoesNotCrashOrHang() async throws {
		let cli = runner(command: "/usr/bin/true")
		let result = try await cli.run(args: [], stdin: String(repeating: "x", count: 2_000_000), outputMode: .none, timeout: 2)
		XCTAssertEqual(result.status, 0)
	}

	func testStreamTailLoggingIsBoundedAndInputSamplingRemainsOptIn() async throws {
		let logs = Logs()
		var config = AgentCLIConfiguration(command: "/bin/sh", workingDirectory: "/tmp", additionalPaths: [], logCollector: logs)
		config.captureStdoutTailBytes = 4; config.captureStderrTailBytes = 3
		let cli = AgentCLIRunner(config: config, host: host())
		let stream = try await cli.runStreaming(args: ["-c", "printf abcdef; printf uvwxyz >&2"], stdin: "private", outputMode: .none, timeout: 2)
		for try await _ in stream {}
		XCTAssertTrue(logs.events.snapshot().contains("STDOUT:cdef"))
		XCTAssertTrue(logs.events.snapshot().contains("STDERR:xyz"))
		XCTAssertFalse(logs.events.snapshot().joined().contains("private"))
	}

	func testEnvironmentOverridesAndRemovalArePassedThroughExplicitHost() async throws {
		var config = AgentCLIConfiguration(command: "/bin/sh", workingDirectory: "/tmp", additionalPaths: [], environment: ["KEPT": "first", "REMOVED": "secret"])
		config.commandSuffix = ["-c"]
		let cli = AgentCLIRunner(config: config, host: host())
		let result = try await cli.run(args: ["printf '%s:%s' \"$KEPT\" \"${REMOVED-unset}\""], stdin: nil, outputMode: .none, timeout: 2, additionalEnvironment: ["KEPT": "second"], additionalRemovedKeys: ["REMOVED"])
		XCTAssertEqual(result.stdout, Data("second:unset".utf8))
	}

	func testCancellationDuringHostPreparationNeverSpawnsAndReleasesPermit() async throws {
		let gate = PreparationGate(); let events = Events(); let base = host(events: events)
		let services = AgentCLIRunner.HostServices(environment: { _, _, _ in await gate.suspend(); return [:] },
			resolveCommand: base.resolveCommand, expandWorkingDirectory: base.expandWorkingDirectory,
			rememberSuccessfulCommand: base.rememberSuccessfulCommand, terminationPolicy: base.terminationPolicy,
			diagnostics: base.diagnostics, readPreflight: base.readPreflight, didStart: base.didStart, didFinish: base.didFinish)
		let cli = AgentCLIRunner(config: .init(command: "/bin/sh", workingDirectory: "/tmp", additionalPaths: []), host: services)
		let task = Task { try await cli.run(args: ["-c", "printf unexpected"], stdin: nil, outputMode: .none, timeout: 2) }
		let entered = await waitUntil { await gate.entered }; XCTAssertTrue(entered)
		task.cancel(); await gate.release()
		do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
		XCTAssertTrue(events.snapshot().isEmpty)
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.stdout, Data("next".utf8))
	}

	func testMultipleActiveChildrenCancelAndFinishExactlyOnceEach() async throws {
		let events = Events()
		let cli = AgentCLIRunner(config: .init(command: "/bin/sh", workingDirectory: "/tmp", additionalPaths: []), host: host(events: events), concurrencyLimit: 2)
		let first = Task { try await cli.run(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil) }
		let second = Task { try await cli.run(args: ["-c", "exec /bin/sleep 30"], stdin: nil, outputMode: .none, timeout: nil) }
		let started = await waitUntil { events.snapshot().count == 2 }; XCTAssertTrue(started)
		await cli.cancelAll()
		_ = try await first.value; _ = try await second.value
		let recorded = events.snapshot()
		XCTAssertEqual(recorded.count, 4)
		XCTAssertEqual(Set(recorded.filter { $0.hasPrefix("start:") }.map { String($0.dropFirst(6)) }),
			Set(recorded.filter { $0.hasPrefix("finish:") }.map { String($0.dropFirst(7)) }))
	}

	func testDescendantHeldOutputPipesHaveABoundedDrainAndReleasePermit() async throws {
		let cli = runner()
		let start = ContinuousClock.now
		let result = try await cli.run(args: ["-c", "/bin/sleep 6 & printf retained"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(result.stdout, Data("retained".utf8))
		XCTAssertLessThan(start.duration(to: .now), .seconds(9))
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.status, 0)
	}

	func testCancelAllInvalidatesSuspendedPreparationBeforeAnySpawn() async throws {
		let gate = PreparationGate(); let events = Events(); let base = host(events: events)
		let services = AgentCLIRunner.HostServices(environment: { _, _, _ in await gate.suspend(); return [:] },
			resolveCommand: base.resolveCommand, expandWorkingDirectory: base.expandWorkingDirectory,
			rememberSuccessfulCommand: base.rememberSuccessfulCommand, terminationPolicy: base.terminationPolicy,
			diagnostics: base.diagnostics, readPreflight: base.readPreflight, didStart: base.didStart, didFinish: base.didFinish)
		let cli = AgentCLIRunner(config: .init(command: "/bin/sh", workingDirectory: "/tmp", additionalPaths: []), host: services)
		let pending = Task { try await cli.run(args: ["-c", "printf unexpected"], stdin: nil, outputMode: .none, timeout: 2) }
		let entered = await waitUntil { await gate.entered }; XCTAssertTrue(entered)
		await cli.cancelAll(); await gate.release()
		do { _ = try await pending.value; XCTFail("Old preparation must be rejected") } catch is CancellationError {}
		XCTAssertTrue(events.snapshot().isEmpty)
		let next = try await cli.run(args: ["-c", "printf next"], stdin: nil, outputMode: .none, timeout: 2)
		XCTAssertEqual(next.stdout, Data("next".utf8))
	}
}
