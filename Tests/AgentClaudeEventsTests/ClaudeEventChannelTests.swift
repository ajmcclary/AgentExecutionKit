import XCTest
import AgentClaudeEvents

@MainActor
final class ClaudeEventChannelTests: XCTestCase {
	private func collect(_ events: AsyncStream<ClaudeNativeEvent>) async -> [String] {
		var values: [String] = []
		for await event in events { if case .error(let text) = event { values.append(text) } }
		return values
	}
	func testEventsKeepOrderAndFinishDrainsBufferedValues() async {
		let owner = ClaudeNativeEventChannel(); owner.emit(.error("a")); owner.emit(.error("b")); owner.finish()
		let values = await collect(owner.events); XCTAssertEqual(values, ["a", "b"]); XCTAssertFalse(owner.isOpen)
	}
	func testFinishIsIdempotentAndLateEmissionIsIgnored() async {
		let owner = ClaudeNativeEventChannel(); owner.finish(); owner.finish(); owner.emit(.error("late"))
		let values = await collect(owner.events); XCTAssertTrue(values.isEmpty)
	}
	func testEnsureReadyKeepsExistingStreamAndBufferedEvents() async {
		let owner = ClaudeNativeEventChannel(); let token = owner.token; owner.emit(.error("keep")); owner.ensureReady()
		XCTAssertEqual(owner.token, token); owner.finish(); let values = await collect(owner.events); XCTAssertEqual(values, ["keep"])
	}
	func testEnsureReadyAfterFinishCreatesNewOpenStream() async {
		let owner = ClaudeNativeEventChannel(); let old = owner.token; owner.finish(); owner.ensureReady()
		XCTAssertNotEqual(owner.token, old); XCTAssertTrue(owner.isOpen)
		owner.emit(.error("new")); owner.finish(); let values = await collect(owner.events); XCTAssertEqual(values, ["new"])
	}
	func testResetFinishesOldStreamAndDoesNotTransferBufferedEvents() async {
		let owner = ClaudeNativeEventChannel(); let old = owner.events; owner.emit(.error("old")); owner.reset(); owner.emit(.error("new")); owner.finish()
		let oldValues = await collect(old); let newValues = await collect(owner.events)
		XCTAssertEqual(oldValues, ["old"]); XCTAssertEqual(newValues, ["new"])
	}
	func testReplacedStreamRejectsOldProducerToken() async {
		let owner = ClaudeNativeEventChannel(); let old = owner.token; owner.reset()
		owner.emit(.error("retired"), for: old); owner.emit(.error("current"), for: owner.token); owner.finish()
		let values = await collect(owner.events); XCTAssertEqual(values, ["current"])
	}
	func testCancelledIteratorDoesNotPoisonResetStream() async {
		let owner = ClaudeNativeEventChannel(); let old = owner.events
		let consumer = Task { await collect(old) }; consumer.cancel(); _ = await consumer.value
		owner.reset(); owner.emit(.error("new")); owner.finish()
		let values = await collect(owner.events); XCTAssertEqual(values, ["new"])
	}
	func testContractsTransferAndSessionRefRemainsMutableValue() async {
		var ref = ClaudeNativeSessionRef(sessionID: " old "); ref.sessionID = "new"
		let value = await Task { ref.sessionID }.value; XCTAssertEqual(value, "new")
		let event = ClaudeNativeEvent.runtimeInit(.init(sessionID: " raw ", tools: ["future"], mcpServerStatuses: [:], initializeResponse: nil))
		let id = await Task { if case .runtimeInit(let metadata) = event { return metadata.sessionID }; return nil }.value
		XCTAssertEqual(id, " raw ")
	}
}
