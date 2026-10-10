import Foundation
import XCTest
import ProcessKit
import AgentACPRPC
import AgentACPProtocol
import AgentACPConnection
import AgentNativeProcessTransport

private enum FixtureError: Error, Equatable { case unavailable, closed, violation(String), failed(String, Int?), timeout, preflight }

@MainActor
private final class Harness {
	let connection: ACPConnection
	var events: [ACPConnection.Event] = []
	var outbound: [ACPJSONObject] = []
	var exits = 0
	var expired = 0
	init(limits: ACPStdoutDecoder.Limits? = nil, failReader: Bool = false, sleep: @escaping ACPRequestStore.Sleep = { try await Task.sleep(for: $0) }) {
		connection = .init(lifecycle: .init(readPreflight: { _, _ in if failReader { throw FixtureError.preflight } },
			waitForTermination: { try? await ProcessTermination.waitForTermination(pid: $0, timeout: nil) },
			terminateAndReap: { _ = await ProcessTermination.terminateAndReap(pid: $0, policy: .init(cooperativeWaitTimeout: .milliseconds(30), sigtermGracePeriod: .milliseconds(30), sigkillGracePeriod: .milliseconds(30))) }),
			errors: .init(unavailable: { FixtureError.unavailable }, closed: { FixtureError.closed }, protocolViolation: { FixtureError.violation($0) }, requestFailed: { FixtureError.failed($0, $1) }), limits: limits, sleep: sleep)
	}
	func spawn(_ script: String = "cat") throws {
		try connection.spawn(.init(command: "/bin/sh", arguments: ["-c", script], environment: [:], workingDirectory: "/tmp"))
	}
	func startReaders() throws {
		try connection.startReaders(onStdout: { [weak self] generation, data in await self?.stdout(data, generation: generation) },
			onStderr: { [weak self] generation, data in await self?.stderr(data, generation: generation) })
	}
	func stdout(_ data: Data, generation: UInt64) { connection.consumeStdout(data, generation: generation) { events.append($0) } }
	func stderr(_ data: Data, generation: UInt64) { connection.consumeStderr(data, generation: generation) { events.append($0) } }
	func feed(_ text: String) { stdout(Data(text.utf8), generation: connection.generation) }
	func request(_ method: String = "initialize", deadline: ACPRequestStore.Deadline? = nil) async throws -> (Int, Task<Data, any Error>) {
		let (stream, yielded) = AsyncStream<ACPJSONObject>.makeStream()
		let task = Task { [weak self] in
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
				guard let self else { continuation.resume(throwing: FixtureError.closed); return }
				self.connection.sendRequest(method: method, params: .empty, continuation: continuation, deadline: deadline) {
					self.outbound.append($0); yielded.yield($0); yielded.finish()
				}
			}
		}
		var iterator = stream.makeAsyncIterator(); let payload = await iterator.next()
		return (try XCTUnwrap(payload?.dictionary()["id"] as? Int), task)
	}
	func expire(_ ticket: ACPRequestStore.Ticket) { connection.expire(ticket) { expired += 1; return FixtureError.timeout } }
	func close() async { await connection.invalidate()?.finish() }
}

@MainActor
final class ACPConnectionTests: XCTestCase {
	private func error(_ task: Task<Data, any Error>, equals expected: FixtureError) async {
		do { _ = try await task.value; XCTFail("Expected failure") } catch { XCTAssertEqual(error as? FixtureError, expected) }
	}
	func testRequestResponseRoutingAndMonotonicIDsAfterReconnect() async throws {
		let h = Harness(); try h.spawn()
		let (id, first) = try await h.request()
		h.feed("{\"id\":\"\(id)\",\"result\":{\"sessionId\":\" raw \"}}\n")
		let result = try await first.value
		XCTAssertEqual(try ACPJSONObject(data: result).dictionary()["sessionId"] as? String, " raw ")
		await h.close(); try h.spawn()
		let (secondID, second) = try await h.request()
		XCTAssertEqual(secondID, id + 1)
		h.feed("{\"id\":\(secondID),\"result\":{}}\n"); _ = try await second.value
		await h.close()
	}
	func testProviderErrorAndMissingResultUseHostErrorFactories() async throws {
		let h = Harness(); try h.spawn()
		let (id, first) = try await h.request("session/load")
		h.feed("{\"id\":\(id),\"error\":{\"code\":-32602,\"message\":\"base\",\"data\":\"detail\"}}\n")
		await error(first, equals: .failed("base: detail", -32602))
		XCTAssertTrue(h.events.contains { if case .requestFailed("session/load", "base: detail", -32602) = $0 { return true }; return false })
		let (next, second) = try await h.request(); h.feed("{\"id\":\(next)}\n")
		await error(second, equals: .violation("Missing result/error for request \(next)")); await h.close()
	}
	func testInvalidObjectAndUnmatchedResponseFailAllPending() async throws {
		let h = Harness(); try h.spawn()
		let (_, first) = try await h.request(); h.feed("[]\n")
		await error(first, equals: .violation("Invalid ACP JSON line: []"))
		let (_, second) = try await h.request(); h.feed("{\"id\":999,\"result\":{}}\n")
		await error(second, equals: .violation("Received unmatched ACP response id 999.")); await h.close()
	}
	func testOverflowFailsAllAndDropsForgedTailAndLaterNotifications() async throws {
		let h = Harness(limits: .init(maxLineBytes: 64, maxCarryBytes: 128, tailRetainBytes: 32)); try h.spawn()
		let (_, first) = try await h.request()
		h.feed(String(repeating: "x", count: 80) + "{\"id\":1}")
		await error(first, equals: .violation("ACP stdout logical line overflowed the framing limit; no bytes of it may be interpreted as a frame"))
		let count = h.events.count; h.feed("\n{\"method\":\"session/update\"}\n")
		XCTAssertEqual(h.events.count, count); XCTAssertTrue(h.connection.stdoutFramingFailed)
		XCTAssertEqual(h.connection.diagnostics.invalidACPLineCount, 1); await h.close()
	}
	func testDiagnosticCountersPreviewsAndStderrWhitespaceMatchHostBaseline() async throws {
		let h = Harness(); try h.spawn()
		let line = "{\"future\":\"" + String(repeating: "é", count: 300) + "\"}"
		h.feed(" \n" + line + "\ninvalid\n")
		h.stderr(Data(" \n  hello  \r\n\u{2003}edge\u{2003}\n".utf8), generation: h.connection.generation)
		let d = h.connection.diagnostics
		XCTAssertEqual(d.stdoutLineCount, 2); XCTAssertEqual(d.invalidACPLineCount, 1)
		XCTAssertEqual(d.lastStdoutPreview, "invalid"); XCTAssertEqual(d.lastInvalidACPLinePreview, "invalid")
		XCTAssertEqual(d.stderrLineCount, 2); XCTAssertEqual(d.lastStderrPreview, "\u{2003}edge\u{2003}")
		XCTAssertTrue(h.events.contains { if case .inboundLine(let s) = $0 { return s == line }; return false })
		await h.close()
	}
	func testStaleChunksExitAndInvalidationCannotTouchReplacement() async throws {
		let h = Harness(); try h.spawn(); let old = h.connection.generation
		await h.close(); try h.spawn()
		let (_, result) = try await h.request()
		h.stdout(Data("{\"id\":2,\"result\":{}}\n".utf8), generation: old)
		h.stderr(Data("stale\n".utf8), generation: old)
		XCTAssertFalse(h.connection.observeExit(expectedGeneration: old)); XCTAssertNil(h.connection.invalidate(expectedGeneration: old))
		XCTAssertEqual(h.connection.pendingMethods, ["initialize"]); XCTAssertTrue(h.events.isEmpty)
		await h.close(); await error(result, equals: .closed)
	}
	func testOutboundObserverInvalidationCannotWriteToReplacementOrDoubleResume() async throws {
		let h = Harness(); try h.spawn(); var lease: AgentNativeProcessTransport.TerminationLease?
		let data: Data
		do {
			data = try await withCheckedThrowingContinuation { continuation in
				h.connection.sendRequest(method: "initialize", params: .empty, continuation: continuation) { _ in
					lease = h.connection.invalidate(); try! h.spawn()
				}
			}
			XCTFail("Unexpected result \(data)")
		} catch { XCTAssertEqual(error as? FixtureError, .closed) }
		XCTAssertTrue(h.connection.hasProcess); XCTAssertTrue(h.connection.pendingMethods.isEmpty)
		await lease?.finish(); await h.close()
	}
	func testInboundObserverInvalidationStopsOldBatchBeforeRouting() async throws {
		let h = Harness(); try h.spawn(); let generation = h.connection.generation
		var lease: AgentNativeProcessTransport.TerminationLease?
		h.connection.consumeStdout(Data("{\"method\":\"first\"}\n{\"method\":\"second\"}\n".utf8), generation: generation) { event in
			h.events.append(event)
			if case .message = event { lease = h.connection.invalidate(); try! h.spawn() }
		}
		XCTAssertEqual(h.events.count, 2); XCTAssertEqual(h.connection.diagnostics.stdoutLineCount, 0)
		await lease?.finish(); await h.close()
	}
	func testReadersCarryOrderedFramesAndStderrOnOwnerExecutor() async throws {
		let h = Harness(); try h.spawn("printf '%s\\n' '{\"method\":\"one\"}' '{\"method\":\"two\"}'; printf 'err\\n' >&2; cat")
		try h.startReaders()
		for _ in 0..<500 {
			if h.connection.diagnostics.stdoutLineCount == 2, h.connection.diagnostics.stderrLineCount == 1 { break }
			try await Task.sleep(for: .milliseconds(2))
		}
		let methods = h.events.compactMap { event -> String? in if case .message(let m) = event { return m.method }; return nil }
		XCTAssertEqual(methods, ["one", "two"]); XCTAssertEqual(h.connection.diagnostics.stderrLineCount, 1)
		await h.close()
	}
	func testReaderPreflightFailureClosesWithoutInstalledWaiter() async throws {
		let h = Harness(failReader: true); try h.spawn(); XCTAssertThrowsError(try h.startReaders())
		XCTAssertFalse(h.connection.hasWaiter); await h.close(); XCTAssertFalse(h.connection.hasProcess)
	}
	func testUnavailableRequestAndWriteUseHostFactoryWithoutRegistration() async throws {
		let h = Harness()
		XCTAssertThrowsError(try h.connection.send(.empty, onOutbound: { _ in XCTFail("No write") })) { XCTAssertEqual($0 as? FixtureError, .unavailable) }
		do {
			let _: Data = try await withCheckedThrowingContinuation { continuation in
				h.connection.sendRequest(method: "initialize", params: .empty, continuation: continuation) { _ in XCTFail("No request") }
			}
			XCTFail("Expected unavailable")
		} catch { XCTAssertEqual(error as? FixtureError, .unavailable) }
		XCTAssertTrue(h.connection.pendingMethods.isEmpty)
	}
	func testConnectionDeadlineIsDeliveredOnHostExecutor() async throws {
		let clock = DeadlineGate()
		let h = Harness(sleep: { _ in await clock.wait() }); try h.spawn()
		let (_, task) = try await h.request(deadline: .init(duration: .seconds(1)) { [weak h] ticket in await h?.expire(ticket) })
		await clock.open(); await error(task, equals: .timeout)
		XCTAssertEqual(h.expired, 1); XCTAssertTrue(h.connection.pendingMethods.isEmpty); await h.close()
	}
	func testActualWriteIsOneNDJSONFrameWithExactUTF8Payload() async throws {
		let h = Harness(); try h.spawn(); try h.startReaders()
		let payload = try ACPJSONObject(object: ["method": "fixture", "params": ["text": "hé 🧭\nnext"]])
		var observed: Data?
		try h.connection.send(payload) { observed = $0.data }
		for _ in 0..<500 {
			if h.connection.diagnostics.stdoutLineCount == 1 { break }
			try await Task.sleep(for: .milliseconds(2))
		}
		let frames = h.events.compactMap { event -> Data? in if case .message(let m) = event { return m.payload.data }; return nil }
		XCTAssertEqual(frames, [payload.data]); XCTAssertEqual(observed, payload.data)
		await h.close()
	}
	func testDroppedConnectionResolvesPendingRequestUsingHostClosedError() async throws {
		var h: Harness? = Harness(); try h?.spawn()
		let (_, task) = try await XCTUnwrap(h).request()
		h = nil
		await error(task, equals: .closed)
	}

	func testNaturalExitRetiresPendingRequestsAndDoesNotReapTwice() async throws {
		let h = Harness(); try h.spawn("read line; exit 7")
		try h.connection.startWaiter { [weak h] generation, code, _ in
			await MainActor.run {
				XCTAssertEqual(code, 7); h?.exits += 1; _ = h?.connection.observeExit(expectedGeneration: generation)
			}
		}
		let (_, task) = try await h.request(); await error(task, equals: .closed)
		XCTAssertEqual(h.exits, 1); XCTAssertNil(h.connection.invalidate())
	}
}

private actor DeadlineGate {
	private var opened = false
	private var waiting: [CheckedContinuation<Void, Never>] = []
	func wait() async {
		if opened { return }
		await withCheckedContinuation { waiting.append($0) }
	}
	func open() {
		opened = true
		let pending = waiting; waiting.removeAll()
		for continuation in pending { continuation.resume() }
	}
}
