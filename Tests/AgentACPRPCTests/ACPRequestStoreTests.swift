import Foundation
import Synchronization
import XCTest
@testable import AgentACPRPC

@MainActor
final class ACPRequestStoreTests: XCTestCase {
	private enum Failure: Error, Equatable { case timeout, write, shutdown }
	private let bytes = Data("{\"ok\":true}".utf8)
	private func pending(_ store: ACPRequestStore, method: String = "test",
						 deadline: ACPRequestStore.Deadline? = nil) async throws
		-> (ACPRequestStore.Ticket, Task<Data, any Error>) {
		let (stream, producer) = AsyncThrowingStream<ACPRequestStore.Ticket, any Error>.makeStream()
		let result = Task { [weak store] in
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
				do {
					guard let store else { throw ACPRequestStore.StoreError.closed }
					let ticket = try store.register(method: method, continuation: continuation, deadline: deadline)
					producer.yield(ticket)
					producer.finish()
				} catch {
					producer.finish(throwing: error)
					continuation.resume(throwing: error)
				}
			}
		}
		var iterator = stream.makeAsyncIterator()
		let ticket = try await iterator.next()
		return (try XCTUnwrap(ticket), result)
	}
	private func assertFailure(_ task: Task<Data, any Error>, _ expected: Failure) async {
		do { _ = try await task.value; XCTFail("Expected failure") }
		catch { XCTAssertEqual(error as? Failure, expected) }
	}

	func testResponseAndDuplicateCompleteExactlyOnce() async throws {
		let store = ACPRequestStore()
		let (ticket, task) = try await pending(store)
		XCTAssertEqual(store.resolve(responseID: .string("1"), with: .success(bytes)), ticket)
		XCTAssertNil(store.resolve(responseID: .int(1), with: .success(Data())))
		let value = try await task.value
		XCTAssertEqual(value, bytes)
		XCTAssertTrue(store.pendingMethods.isEmpty)
	}
	func testStrictIdentityAndNoncanonicalEchoCannotResolve() async throws {
		let store = ACPRequestStore(matching: .strict)
		let (ticket, task) = try await pending(store)
		XCTAssertNil(store.resolve(responseID: .string("1"), with: .success(bytes)))
		XCTAssertEqual(store.resolve(responseID: ticket.id, with: .success(bytes)), ticket)
		_ = try await task.value
		let compatible = ACPRequestStore()
		let (second, result) = try await pending(compatible)
		for text in ["+1", "01", "-0", " 1", "1e0", "1.0", "1e300"] {
			XCTAssertNil(compatible.resolve(responseID: .string(text), with: .success(bytes)))
		}
		compatible.resolve(responseID: second.id, with: .success(bytes))
		_ = try await result.value
	}
	func testWriteFailureAndExplicitCancellationDoNotAffectOtherRequests() async throws {
		let store = ACPRequestStore()
		let (first, a) = try await pending(store, method: "first")
		let (second, b) = try await pending(store, method: "second")
		XCTAssertTrue(store.cancel(first, error: Failure.write))
		XCTAssertFalse(store.cancel(first))
		XCTAssertEqual(store.pendingMethods, ["second"])
		store.cancel(second)
		await assertFailure(a, .write)
		do { _ = try await b.value; XCTFail("Expected cancellation") }
		catch { XCTAssertTrue(error is CancellationError) }
	}
	func testFailAllAndStaleResponseKeepMonotonicIDs() async throws {
		let store = ACPRequestStore()
		let (old, a) = try await pending(store, method: "z")
		let (_, b) = try await pending(store, method: "a")
		XCTAssertEqual(store.pendingMethods, ["a", "z"])
		store.failAll(with: Failure.shutdown)
		await assertFailure(a, .shutdown); await assertFailure(b, .shutdown)
		let (new, task) = try await pending(store)
		XCTAssertEqual(new.id, .int(3))
		XCTAssertNil(store.resolve(responseID: old.id, with: .success(bytes)))
		XCTAssertFalse(store.cancel(old))
		store.resolve(responseID: new.id, with: .success(bytes))
		_ = try await task.value
	}
	func testConcurrentResponseCancellationAndTeardownHaveOneWinner() async throws {
		let store = ACPRequestStore()
		let (ticket, task) = try await pending(store)
		let wins = Mutex(0)
		await withTaskGroup(of: Void.self) { group in
			for index in 0..<100 {
				group.addTask {
					let won: Bool
					if index.isMultiple(of: 2) {
						won = store.resolve(responseID: ticket.id, with: .success(Data())) != nil
					} else { won = store.cancel(ticket, error: Failure.shutdown) }
					if won { wins.withLock { $0 += 1 } }
				}
			}
		}
		XCTAssertEqual(wins.withLock { $0 }, 1)
		_ = await task.result
		store.failAll(with: Failure.shutdown)
		XCTAssertTrue(store.pendingMethods.isEmpty)
	}
	func testInjectedDeadlineClaimsBeforeHostErrorFactoryAndIsReentrant() async throws {
		let clock = Gate()
		let store = ACPRequestStore(sleep: { _ in await clock.wait() })
		let calls = Mutex(0)
		let (_, task) = try await pending(store, deadline: .init(duration: .seconds(1)) { ticket in
			store.expire(ticket) {
				XCTAssertTrue(store.pendingMethods.isEmpty)
				store.failAll(with: Failure.shutdown)
				calls.withLock { $0 += 1 }
				return Failure.timeout
			}
		})
		await clock.open()
		await assertFailure(task, .timeout)
		XCTAssertEqual(calls.withLock { $0 }, 1)
	}
	func testResolvedDeadlineCannotExpireReplacementOrInvokeDiagnostics() async throws {
		let clock = Gate()
		let store = ACPRequestStore(sleep: { _ in await clock.wait() })
		let calls = Mutex(0)
		let (old, first) = try await pending(store, deadline: .init(duration: .seconds(1)) { ticket in
			store.expire(ticket) { calls.withLock { $0 += 1 }; return Failure.timeout }
		})
		store.resolve(responseID: old.id, with: .success(bytes))
		_ = try await first.value
		let (new, second) = try await pending(store)
		await clock.open()
		store.resolve(responseID: new.id, with: .success(bytes))
		_ = try await second.value
		XCTAssertEqual(calls.withLock { $0 }, 0)
	}
	func testQueuedExpiryAfterResponseDoesNotProduceDiagnostics() async throws {
		let clock = Gate(), delivery = Gate()
		let (arrivals, arrived) = AsyncStream<Void>.makeStream()
		let (completions, completed) = AsyncStream<Void>.makeStream()
		let store = ACPRequestStore(sleep: { _ in await clock.wait() })
		let calls = Mutex(0)
		let (ticket, task) = try await pending(store, deadline: .init(duration: .seconds(1)) { ticket in
			arrived.yield(()); arrived.finish()
			await delivery.wait()
			store.expire(ticket) { calls.withLock { $0 += 1 }; return Failure.timeout }
			completed.yield(()); completed.finish()
		})
		await clock.open()
		for await _ in arrivals { break }
		store.resolve(responseID: ticket.id, with: .success(bytes))
		_ = try await task.value
		await delivery.open()
		for await _ in completions { break }
		XCTAssertEqual(calls.withLock { $0 }, 0)
	}
	func testCallerCancellationRemainsExplicitHostPolicy() async throws {
		let store = ACPRequestStore()
		let (ticket, task) = try await pending(store, method: "session/prompt")
		task.cancel()
		XCTAssertEqual(store.pendingMethods, ["session/prompt"])
		store.resolve(responseID: ticket.id, with: .success(bytes))
		let value = try await task.value
		XCTAssertEqual(value, bytes)
	}

	func testZeroDeadlineDoesNotScheduleAndDroppedOwnerResolves() async throws {
		let calls = Mutex(0)
		var store: ACPRequestStore? = ACPRequestStore(sleep: { _ in calls.withLock { $0 += 1 } })
		let (_, task) = try await pending(try XCTUnwrap(store), deadline: .init(duration: .zero) { _ in XCTFail("Zero deadline must not fire") })
		store = nil
		do { _ = try await task.value; XCTFail("Expected closed") }
		catch { XCTAssertTrue(error is ACPRequestStore.StoreError) }
		XCTAssertEqual(calls.withLock { $0 }, 0)
	}
}

private actor Gate {
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
