import Foundation

public actor AgentSessionDiskWriter {
	private struct PendingWrite {
		var pendingData: Data?
		var isWriting: Bool
		/// Callers whose snapshot is (or was coalesced into) `pendingData`.
		var waiters: [CheckedContinuation<Void, Error>]
		/// Callers whose snapshot the in-flight write carries.
		var inFlightWaiters = 0
	}

	public typealias Write = @Sendable (Data, URL) async throws -> Void
	private let write: Write
	public init(write: @escaping Write = { data, url in
		try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
	}) { self.write = write }

	private var pendingByURL: [URL: PendingWrite] = [:]

	public func enqueueAndWait(data: Data, url: URL) async throws {
		try await withCheckedThrowingContinuation { continuation in
			var pending = pendingByURL[url] ?? PendingWrite(
				pendingData: nil,
				isWriting: false,
				waiters: []
			)
			pending.pendingData = data
			pending.waiters.append(continuation)
			let shouldStartWriter = !pending.isWriting
			pending.isWriting = true
			pendingByURL[url] = pending
			if shouldStartWriter {
				Task { await self.drainWrites(for: url) }
			}
		}
	}

	/// Each write carries the latest snapshot and the callers whose snapshots it
	/// supersedes. Those callers are resumed with THAT write's result as soon as
	/// it completes: an early caller is not held while newer saves keep arriving,
	/// and nobody receives the result of a write that did not carry its bytes.
	private func drainWrites(for url: URL) async {
		while true {
			guard var pending = pendingByURL[url] else { return }
			guard let data = pending.pendingData else {
				pendingByURL.removeValue(forKey: url)
				for waiter in pending.waiters { waiter.resume(returning: ()) }
				return
			}
			let carried = pending.waiters
			pending.pendingData = nil
			pending.waiters = []
			pending.inFlightWaiters = carried.count
			pendingByURL[url] = pending

			let writeResult: Result<Void, Error>
			do { try await write(data, url); writeResult = .success(()) }
			catch { writeResult = .failure(error) }

			pendingByURL[url]?.inFlightWaiters = 0
			for waiter in carried { waiter.resume(with: writeResult) }
		}
	}
	@_spi(Testing) public func pendingWaiterCount(for url: URL) -> Int {
		guard let pending = pendingByURL[url] else { return 0 }
		return pending.waiters.count + pending.inFlightWaiters
	}

}
