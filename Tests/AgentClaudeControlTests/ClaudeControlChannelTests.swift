import XCTest
import Foundation
import Synchronization
import AgentClaudeProtocol
@testable import AgentClaudeControl

@MainActor
final class ClaudeControlChannelTests: XCTestCase {
	enum Failure: Error, Equatable { case unavailable, invalid(String), timeout(String), write, closed }
	@MainActor final class Host {
		let channel: ClaudeControlChannel
		var timeoutCount = 0
		init(prefix: String = "rp-claude-", sleep: @escaping ClaudeControlChannel.Sleep = { try await Task.sleep(for: $0) }) {
			channel = .init(requestIDPrefix: prefix, errors: .init(unavailable: { Failure.unavailable },
				invalidResponse: { Failure.invalid($0) }, timedOut: { Failure.timeout($0) }), sleep: sleep)
		}
		func expire(_ ticket: ClaudeControlChannel.Ticket) { if channel.expire(ticket) { timeoutCount += 1 } }
	}
	final class Clock: Sendable {
		let pair = AsyncStream<Void>.makeStream()
		let began = Mutex(false)
		func sleep(_ duration: Duration) async throws {
			began.withLock { $0 = true }
			for await _ in pair.stream { return }
			throw CancellationError()
		}
	}
	private func response(_ id: String, subtype: String = "success", payload: [String: Any]? = nil,
		error: String? = nil, pending: [[String: Any]] = []) throws -> ClaudeNativeProtocolCodec.ControlResponse {
		var object: [String: Any] = ["request_id": id, "subtype": subtype, "pending_permission_requests": pending]
		object["response"] = payload; object["error"] = error
		let data = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": object])
		guard case .controlResponse(let result)? = try ClaudeNativeProtocolCodec.decodeLine(data) else { throw Failure.closed }
		return result
	}
	private func wait(_ condition: () -> Bool) async {
		for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
		XCTAssertTrue(condition(), "Condition did not become ready")
	}
	private func start(_ host: Host, deadline: ClaudeControlChannel.Deadline? = nil,
		write: @escaping (Data) throws -> Void = { _ in }) -> Task<ClaudeProtocolJSONObject, any Error> {
		Task {
			try await host.channel.request(.init(object: ["subtype": "initialize"]), deadline: deadline,
				isAvailable: { true }, observe: { _, _ in }, write: write)
		}
	}
	private func accept(_ host: Host, _ value: ClaudeNativeProtocolCodec.ControlResponse) -> Bool {
		host.channel.receive(value, observe: { _ in }, recoverPermission: { _ in XCTFail("Unexpected permission") })
	}
	private func assertFailure(_ task: Task<ClaudeProtocolJSONObject, any Error>, _ expected: Failure) async {
		do { _ = try await task.value; XCTFail("Expected failure") }
		catch { XCTAssertEqual(error as? Failure, expected) }
	}

	func testRegistersBeforeWriteAndPreservesEnvelopeAndResponsePrecision() async throws {
		let host = Host(); var observed: [String] = []
		let value = try await host.channel.request(.init(object: ["subtype": "initialize", "future": "@🧭"]),
			isAvailable: { true }, observe: { ticket, expects in
				XCTAssertTrue(expects); observed.append(ticket.requestID)
			}, write: { bytes in
				XCTAssertEqual(host.channel.pendingRequestIDs, ["rp-claude-1"])
				let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
				XCTAssertEqual(wire["type"] as? String, "control_request")
				XCTAssertEqual(wire["request_id"] as? String, "rp-claude-1")
				XCTAssertEqual((wire["request"] as? [String: Any])?["future"] as? String, "@🧭")
				let large = try ClaudeNativeProtocolCodec.decodeLine(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"rp-claude-1","response":{"large":9007199254740993,"future":true}}}"#.utf8))
				guard case .controlResponse(let reply)? = large else { return XCTFail("Missing response") }
				XCTAssertTrue(accept(host, reply))
			})
		let transferred = try await Task { (try value.dictionary()["large"] as? NSNumber)?.stringValue }.value
		XCTAssertEqual(transferred, "9007199254740993")
		XCTAssertEqual(observed, ["rp-claude-1"]); XCTAssertTrue(host.channel.pendingRequestIDs.isEmpty)
	}
	func testNotificationsShareMonotonicNamespaceAndHaveNoWaiter() async throws {
		let host = Host(prefix: "editor-"); var ids: [String] = []
		try host.channel.notify(.init(object: ["subtype": "interrupt"]), isAvailable: { true },
			observe: { ticket, expects in ids.append(ticket.requestID); XCTAssertFalse(expects) }, write: { _ in })
		let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertEqual(host.channel.pendingRequestIDs, ["editor-2"])
		XCTAssertTrue(accept(host, try response("editor-2"))); _ = try await task.value
		host.channel.failAll(with: Failure.closed)
		try host.channel.notify(.init(object: ["subtype": "interrupt"]), isAvailable: { true },
			observe: { ticket, _ in ids.append(ticket.requestID) }, write: { _ in })
		XCTAssertEqual(ids, ["editor-1", "editor-3"])
	}
	func testUnavailableDoesNotObserveWriteOrConsumeID() async throws {
		let host = Host()
		do {
			_ = try await host.channel.request(.init(object: [:]), isAvailable: { false },
				observe: { _, _ in XCTFail("Unavailable") }, write: { _ in XCTFail("Unavailable") })
			XCTFail("Expected unavailable")
		} catch { XCTAssertEqual(error as? Failure, .unavailable) }
		XCTAssertThrowsError(try host.channel.notify(.init(object: [:]), isAvailable: { false },
			observe: { _, _ in XCTFail("Unavailable") }, write: { _ in XCTFail("Unavailable") }))
		let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertTrue(accept(host, try response("rp-claude-1"))); _ = try await task.value
	}
	func testUnknownDuplicateAndCaseDifferentRepliesHaveNoSideEffects() async throws {
		let host = Host(); let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		for id in ["unknown", "RP-CLAUDE-1"] {
			XCTAssertFalse(host.channel.receive(try response(id, subtype: "error", pending: [["request_id": "p", "request": [:]]]),
				observe: { _ in XCTFail("Unmatched") }, recoverPermission: { _ in XCTFail("Unmatched") }))
		}
		XCTAssertTrue(accept(host, try response("rp-claude-1"))); _ = try await task.value
		XCTAssertFalse(accept(host, try response("rp-claude-1")))
	}
	func testSuccessWithoutPayloadIsEmptyObject() async throws {
		let host = Host(); let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertTrue(accept(host, try response("rp-claude-1")))
		let value = try await task.value
		XCTAssertTrue(try value.dictionary().isEmpty)
	}
	func testErrorObservesAndRecoversOnlyWellFormedPermissionsInOrder() async throws {
		let host = Host(); let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		var order: [String] = []
		let pending: [[String: Any]] = [["request_id": "p1", "request": ["subtype": "can_use_tool", "future": 9]],
			["request_id": 7, "request": [:]], ["request_id": "bad", "request": "bad"], ["request_id": "p2", "request": [:]]]
		XCTAssertTrue(host.channel.receive(try response("rp-claude-1", subtype: "error", error: "denied", pending: pending),
			observe: { _ in order.append("observed"); XCTAssertTrue(host.channel.pendingRequestIDs.isEmpty) },
			recoverPermission: { value in
				order.append(value.requestID)
				XCTAssertEqual(value.subtype, value.requestID == "p1" ? "can_use_tool" : "")
			}))
		XCTAssertEqual(order, ["observed", "p1", "p2"]); await assertFailure(task, .invalid("denied"))
	}
	func testUnknownAndMissingErrorVocabularyRemainExact() async throws {
		let host = Host()
		for (subtype, message) in [("error", "Unknown Claude control error"), ("future", "Unsupported subtype: future")] {
			let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
			let id = try XCTUnwrap(host.channel.pendingRequestIDs.first)
			XCTAssertTrue(accept(host, try response(id, subtype: subtype)))
			await assertFailure(task, .invalid(message))
		}
	}
	func testWriteFailureRemovesWaiterAndLateReplyIsIgnored() async throws {
		let host = Host(); let task = start(host, write: { _ in throw Failure.write })
		await assertFailure(task, .write); XCTAssertTrue(host.channel.pendingRequestIDs.isEmpty)
		XCTAssertFalse(accept(host, try response("rp-claude-1")))
	}
	func testSynchronousReplyThenWriteFailureDoesNotDoubleResume() async throws {
		let host = Host(); let task = start(host, write: { _ in
			XCTAssertTrue(self.accept(host, try self.response("rp-claude-1"))); throw Failure.write
		})
		_ = try await task.value; XCTAssertTrue(host.channel.pendingRequestIDs.isEmpty)
	}
	func testReentrantShutdownDuringWriteResumesOnce() async {
		let host = Host(); let task = start(host, write: { _ in
			host.channel.failAll(with: Failure.closed); throw Failure.write
		})
		await assertFailure(task, .closed)
	}
	func testMatchedObservationCanReenterWithoutTakingSameRequest() async throws {
		let host = Host(); let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		let reply = try response("rp-claude-1")
		XCTAssertTrue(host.channel.receive(reply, observe: { _ in
			XCTAssertFalse(accept(host, reply)); host.channel.failAll(with: Failure.closed)
		}, recoverPermission: { _ in }))
		_ = try await task.value
	}
	func testFailAllDrainsMultipleWaitersAndRetainsMonotonicIDs() async throws {
		let host = Host(); let first = start(host); let second = start(host)
		await wait { host.channel.pendingRequestIDs.count == 2 }
		host.channel.failAll(with: Failure.closed); host.channel.failAll(with: Failure.closed)
		await assertFailure(first, .closed); await assertFailure(second, .closed)
		let next = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertEqual(host.channel.pendingRequestIDs, ["rp-claude-3"])
		XCTAssertFalse(accept(host, try response("rp-claude-1")))
		XCTAssertTrue(accept(host, try response("rp-claude-3"))); _ = try await next.value
	}
	func testCallerCancellationWaitsForAuthoritativeProtocolReply() async throws {
		let host = Host(); let task = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		task.cancel(); await Task.yield()
		XCTAssertEqual(host.channel.pendingRequestIDs, ["rp-claude-1"])
		XCTAssertTrue(accept(host, try response("rp-claude-1"))); _ = try await task.value
	}
	func testInjectedDeadlineExpiresOnHostExecutorAndRejectsLateReply() async throws {
		let clock = Clock(); let host = Host(sleep: { try await clock.sleep($0) })
		let task = start(host, deadline: .init(duration: .seconds(5), onExpiry: { await host.expire($0) }))
		await wait { clock.began.withLock { $0 } }; clock.pair.continuation.yield(())
		await assertFailure(task, .timeout("rp-claude-1")); XCTAssertEqual(host.timeoutCount, 1)
		XCTAssertFalse(accept(host, try response("rp-claude-1")))
	}
	func testReplyCancelsDeadlineAndStaleTicketCannotExpireNextRequest() async throws {
		let clock = Clock(); let host = Host(sleep: { try await clock.sleep($0) })
		var ticket: ClaudeControlChannel.Ticket?
		let task = Task {
			try await host.channel.request(.init(object: [:]), deadline: .init(duration: .seconds(5), onExpiry: { await host.expire($0) }),
				isAvailable: { true }, observe: { value, _ in ticket = value }, write: { _ in })
		}
		await wait { clock.began.withLock { $0 } }
		XCTAssertTrue(accept(host, try response("rp-claude-1"))); _ = try await task.value
		clock.pair.continuation.yield(())
		let next = start(host); await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertFalse(host.channel.expire(try XCTUnwrap(ticket)))
		XCTAssertEqual(host.timeoutCount, 0)
		XCTAssertTrue(accept(host, try response("rp-claude-2"))); _ = try await next.value
	}
	func testZeroDeadlineDoesNotScheduleSleep() async throws {
		let host = Host(sleep: { _ in XCTFail("Zero deadline"); throw CancellationError() })
		let task = start(host, deadline: .init(duration: .zero, onExpiry: { _ in XCTFail("Zero deadline") }))
		await wait { !host.channel.pendingRequestIDs.isEmpty }
		XCTAssertTrue(accept(host, try response("rp-claude-1"))); _ = try await task.value
	}
	func testStoreResponseFailureAndShutdownRaceExactlyOnce() async throws {
		for _ in 0..<50 {
			let store = ClaudeControlRequestStore(prefix: "test-", sleep: { try await Task.sleep(for: $0) })
			let ticket = try store.nextTicket()
			let task = Task {
				try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClaudeProtocolJSONObject, any Error>) in
					store.register(ticket, continuation: continuation, deadline: nil)
				}
			}
			await wait { !store.pendingRequestIDs.isEmpty }
			await withTaskGroup(of: Void.self) { group in
				group.addTask { if let pending = store.take(ticket.requestID) { pending.continuation.resume(returning: ClaudeControlRequestStore.emptyObject) } }
				group.addTask { store.fail(ticket, with: Failure.write) }
				group.addTask { store.failAll(with: Failure.closed) }
			}
			_ = await task.result; XCTAssertTrue(store.pendingRequestIDs.isEmpty)
		}
	}
}
