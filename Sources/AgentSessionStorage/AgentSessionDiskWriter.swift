import Foundation

public actor AgentSessionDiskWriter {
	private struct PendingWrite {
		var pendingData: Data?
		var isWriting: Bool
		var waiters: [CheckedContinuation<Void, Error>]
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

	private func drainWrites(for url: URL) async {
		var lastError: Error?
		while true {
			guard var pending = pendingByURL[url] else { return }
			guard let data = pending.pendingData else {
				pending.isWriting = false
				let waiters = pending.waiters
				pendingByURL.removeValue(forKey: url)
				for waiter in waiters {
					if let lastError {
						waiter.resume(throwing: lastError)
					} else {
						waiter.resume(returning: ())
					}
				}
				return
			}
			pending.pendingData = nil
			pendingByURL[url] = pending

			let writeResult: Result<Void, Error>
			do { try await write(data, url); writeResult = .success(()) }
			catch { writeResult = .failure(error) }

			switch writeResult {
			case .success:
				lastError = nil
			case .failure(let error):
				lastError = error
			}
		}
	}
	@_spi(Testing) public func pendingWaiterCount(for url: URL) -> Int { pendingByURL[url]?.waiters.count ?? 0 }

}

