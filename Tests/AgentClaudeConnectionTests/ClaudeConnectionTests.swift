import Foundation
import XCTest
import ProcessKit
import ProcessStreamFraming
import AgentClaudeProtocol
import AgentClaudeConnection
import AgentNativeProcessTransport

private enum FixtureError: Error { case unavailable, write(String), preflight, decode }
@MainActor
private final class Harness {
	let connection: ClaudeConnection
	var events: [ClaudeConnection.Event] = []
	var eofCount = 0
	var allowPlaintext = false
	init(framing: LineFramer.Limits = .default, decoder: ClaudeProtocolLineDecoder = .init(), failReader: Bool = false) {
		connection = .init(lifecycle: .init(readPreflight: { _, label in
			if failReader && label.contains("stderr") { throw FixtureError.preflight }
		}, waitForTermination: { try? await ProcessTermination.waitForTermination(pid: $0, timeout: nil) },
			terminateAndReap: { _ = await ProcessTermination.terminateAndReap(pid: $0, policy: .init(cooperativeWaitTimeout: .milliseconds(30), sigtermGracePeriod: .milliseconds(30), sigkillGracePeriod: .milliseconds(30))) }),
			errors: .init(unavailable: { FixtureError.unavailable }, inputWriteFailed: { FixtureError.write($0) }), framingLimits: framing, decoder: decoder)
	}
	func spawn(_ script: String = "cat") throws { try connection.spawn(.init(command: "/bin/sh", arguments: ["-c", script], environment: [:], workingDirectory: "/tmp")) }
	func readers() throws {
		try connection.startReaders(onStdout: { [weak self] generation, data in await self?.stdout(data, generation) },
			onStderr: { [weak self] generation, data in await self?.stderr(data, generation) },
			onStdoutEOF: { [weak self] generation in await self?.eof(generation) })
	}
	func stdout(_ data: Data, _ generation: UInt64) { connection.consumeStdout(data, generation: generation, allowPlaintext: { allowPlaintext }) { events.append($0) } }
	func stderr(_ data: Data, _ generation: UInt64) { connection.consumeStderr(data, generation: generation) { events.append($0) } }
	func eof(_ generation: UInt64) { connection.flushStdout(generation: generation, allowPlaintext: { allowPlaintext }) { events.append($0) }; eofCount += 1 }
	func feed(_ text: String) { stdout(Data(text.utf8), connection.generation) }
	func close() async { await connection.invalidate()?.finish() }
	var messages: [ClaudeNativeProtocolCodec.InboundMessage] {
		events.compactMap { if case .protocolEvent(.message(let message)) = $0 { return message }; return nil }
	}
}
@MainActor
final class ClaudeConnectionTests: XCTestCase {
	private let keepAlive = #"{"type":"keep_alive"}"#
	private func wait(_ condition: () -> Bool) async -> Bool {
		for _ in 0..<250 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
		return condition()
	}
	func testWriteAddsExactlyOneNewlineAndReadersDeliverTypedFrames() async throws {
		let h = Harness(); try h.spawn(); try h.readers()
		var outbound: [Data] = []
		try h.connection.writeLine(Data(keepAlive.utf8)) { outbound.append($0) }
		let received = await wait { h.messages.count == 1 }; XCTAssertTrue(received)
		XCTAssertEqual(outbound, [Data(keepAlive.utf8)])
		let lines = h.events.compactMap { if case .inboundLine(let data) = $0 { return data }; return nil }
		XCTAssertEqual(lines, [Data(keepAlive.utf8)]); await h.close()
	}
	func testFragmentedUtf8AndTrailingEOFFlushRemainOrdered() async throws {
		let h = Harness(); try h.spawn()
		let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"é🦊"}]}}"#
		let bytes = Data((line + "\n" + keepAlive).utf8)
		for byte in bytes { h.stdout(Data([byte]), h.connection.generation) }
		XCTAssertEqual(h.messages.count, 1)
		h.eof(h.connection.generation); h.eof(h.connection.generation)
		XCTAssertEqual(h.messages.count, 2); await h.close()
	}
	func testActualEOFDeliversFinalPartialLineOnce() async throws {
		let h = Harness(); try h.spawn("printf '%s' '{\"type\":\"keep_alive\"}'"); try h.readers()
		let finished = await wait { h.eofCount == 1 }; XCTAssertTrue(finished)
		XCTAssertEqual(h.messages.count, 1); await h.close()
	}
	func testStaleStdoutStderrFlushAndInvalidationCannotTouchReplacement() async throws {
		let h = Harness(); try h.spawn(); let old = h.connection.generation; await h.close(); try h.spawn()
		h.stdout(Data((keepAlive + "\n").utf8), old); h.stderr(Data("old".utf8), old)
		h.connection.flushStdout(generation: old, allowPlaintext: { true }) { h.events.append($0) }
		XCTAssertNil(h.connection.invalidate(expectedGeneration: old)); XCTAssertTrue(h.connection.hasProcess)
		XCTAssertTrue(h.events.isEmpty); XCTAssertTrue(h.connection.stderrTail.isEmpty)
		h.feed(keepAlive + "\n"); XCTAssertEqual(h.messages.count, 1); await h.close()
	}
	func testReconnectDropsPriorPartialFrameAndStderrTail() async throws {
		let h = Harness(); try h.spawn(); h.feed("{\"type\":")
		h.stderr(Data("old".utf8), h.connection.generation); await h.close(); try h.spawn()
		XCTAssertTrue(h.connection.stderrTail.isEmpty)
		h.feed(keepAlive + "\n"); XCTAssertEqual(h.messages.count, 1); await h.close()
	}
	func testRawLineCallbackReplacementStopsDecodingAndRemainingOldLines() async throws {
		let h = Harness(); try h.spawn(); var lease: AgentNativeProcessTransport.TerminationLease?
		h.connection.consumeStdout(Data((keepAlive + "\n" + keepAlive + "\n").utf8), generation: h.connection.generation, allowPlaintext: { false }) { event in
			h.events.append(event)
			if case .inboundLine = event { lease = h.connection.invalidate(); try? h.spawn() }
		}
		XCTAssertEqual(h.events.count, 1); XCTAssertTrue(h.messages.isEmpty)
		await lease?.finish(); await h.close()
	}
	func testRecoveryObservationReplacementStopsRetiredSegmentMessages() async throws {
		let h = Harness(); try h.spawn(); var lease: AgentNativeProcessTransport.TerminationLease?
		h.connection.consumeStdout(Data((keepAlive + keepAlive + "\n").utf8), generation: h.connection.generation, allowPlaintext: { false }) { event in
			h.events.append(event)
			if case .protocolEvent(.recoveredSegment) = event { lease = h.connection.invalidate(); try? h.spawn() }
		}
		XCTAssertEqual(h.events.count, 2); XCTAssertTrue(h.messages.isEmpty)
		await lease?.finish(); await h.close()
	}
	func testPlaintextPermissionIsReevaluatedForEachFrame() async throws {
		let h = Harness(); try h.spawn(); var active = true
		let narrative = "The investigation was exploring why tool events appeared while assistant text never rendered."
		h.connection.consumeStdout(Data((keepAlive + "\n" + narrative + "\n").utf8), generation: h.connection.generation, allowPlaintext: { active }) { event in
			h.events.append(event); if case .protocolEvent(.message) = event { active = false }
		}
		XCTAssertTrue(h.events.contains { if case .protocolEvent(.skipped) = $0 { return true }; return false })
		XCTAssertFalse(h.events.contains { if case .protocolEvent(.recoveredPlaintext) = $0 { return true }; return false }); await h.close()
	}
	func testFramerOverflowObservationPrecedesAnyDecodedTail() async throws {
		let h = Harness(framing: .init(maxLineBytes: 32, maxCarryBytes: 48, tailRetainBytes: 24)); try h.spawn()
		h.feed(String(repeating: "x", count: 100) + keepAlive)
		h.feed("\n")
		guard case .framing(.overflow) = h.events.first else { await h.close(); return XCTFail("missing leading overflow") }
		await h.close()
	}
	func testStderrTailRetainsLast256KBAndOriginalObservationBytes() async throws {
		let h = Harness(); try h.spawn(); let bytes = Data(repeating: 65, count: 300 * 1024)
		h.stderr(bytes, h.connection.generation)
		XCTAssertEqual(h.connection.stderrTail, Data(bytes.suffix(256 * 1024)))
		guard case .stderr(let observed) = h.events.last else { await h.close(); return XCTFail("missing stderr") }
		XCTAssertEqual(observed, bytes); await h.close()
	}
	func testFatalDecodeStopsFollowingFramesUntilReconnect() async throws {
		let h = Harness(decoder: .init(codec: { _ in throw FixtureError.decode })); try h.spawn()
		let failure = h.connection.consumeStdout(Data("first\nsecond\n".utf8), generation: h.connection.generation, allowPlaintext: { false }) { h.events.append($0) }
		XCTAssertEqual(failure?.preview, "first"); XCTAssertEqual(h.events.count, 2)
		h.feed("third\n"); XCTAssertEqual(h.events.count, 2)
		await h.close(); try h.spawn(); XCTAssertNil(h.connection.decodeFailure); await h.close()
	}
	func testFatalObservationReplacementDoesNotReturnFailureForNewProcess() async throws {
		let h = Harness(decoder: .init(codec: { _ in throw FixtureError.decode })); try h.spawn()
		var lease: AgentNativeProcessTransport.TerminationLease?
		let failure = h.connection.consumeStdout(Data("bad\n".utf8), generation: h.connection.generation, allowPlaintext: { false }) { event in
			if case .protocolEvent(.failed) = event { lease = h.connection.invalidate(); try? h.spawn() }
		}
		XCTAssertNil(failure); XCTAssertNil(h.connection.decodeFailure)
		await lease?.finish(); await h.close()
	}
	func testOutboundObservationCannotWriteRetiredFrameIntoReplacement() async throws {
		let h = Harness(); try h.spawn(); var lease: AgentNativeProcessTransport.TerminationLease?
		XCTAssertThrowsError(try h.connection.writeLine(Data(keepAlive.utf8)) { _ in lease = h.connection.invalidate(); try? h.spawn() })
		try h.readers(); try? await Task.sleep(for: .milliseconds(50)); XCTAssertTrue(h.messages.isEmpty)
		await lease?.finish(); await h.close()
	}
	func testUnavailableWriteUsesHostErrorAndDoesNotObserveOutbound() {
		let h = Harness()
		XCTAssertThrowsError(try h.connection.writeLine(Data()) { _ in XCTFail("unavailable outbound") }) { XCTAssertTrue($0 is FixtureError) }
	}
	func testPartialReaderSetupFailureRetainsExplicitCleanupOwnership() async throws {
		let h = Harness(failReader: true); try h.spawn()
		XCTAssertThrowsError(try h.readers()); XCTAssertTrue(h.connection.hasProcess)
		await h.close(); XCTAssertFalse(h.connection.hasProcess); try h.spawn(); await h.close()
	}
}
