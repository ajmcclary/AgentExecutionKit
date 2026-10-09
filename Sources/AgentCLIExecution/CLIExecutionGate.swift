import Foundation
import ProcessKit

/// Cancellation is attached to a queued waiter, with no retained cancellation
/// tombstones. A granted permit is always returned by its operation owner.
actor CLIExecutionGate {
	private var permits: Int
	private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
	init(_ count: Int) { permits = max(1, count) }
	func acquire() async throws {
		try Task.checkCancellation()
		if permits > 0 { permits -= 1; return }
		let id = UUID()
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
				if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
				else { waiters.append((id, continuation)) }
			}
		} onCancel: { Task { await self.cancel(id) } }
	}
	private func cancel(_ id: UUID) {
		guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
		waiters.remove(at: index).1.resume(throwing: CancellationError())
	}
	func release() {
		if waiters.isEmpty { permits += 1 }
		else { waiters.removeFirst().1.resume() }
	}
	func cancelQueued() {
		let pending = waiters; waiters.removeAll()
		for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
	}
}

actor CLIExecutionRegistry {
	private var jobs: [UUID: CLIExecutionJob] = [:]
	private var generation: UInt64 = 0
	func currentGeneration() -> UInt64 { generation }
	func spawn(command: String, arguments: [String], environment: [String: String], directory: String,
		expectedGeneration: UInt64) throws -> (UUID, CLIExecutionJob, Int32) {
		guard expectedGeneration == generation else { throw CancellationError() }
		let process = try ProcessLauncher.spawn(command: command, arguments: arguments, environment: environment, workingDirectory: directory)
		let id = UUID(); let job = CLIExecutionJob(process)
		jobs[id] = job
		return (id, job, process.pid)
	}
	func remove(_ id: UUID) { jobs[id] = nil }
	func cancelGeneration() -> [CLIExecutionJob] { generation &+= 1; return Array(jobs.values) }
}
