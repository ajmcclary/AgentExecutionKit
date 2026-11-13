import Foundation
import Darwin
import Synchronization
import ProcessKit
import ProcessStreamFraming

/// One child, one waiter, one descriptor/reader cleanup owner. Cancellation
/// only cancels that waiter; it never installs another waitpid/reap path.
actor CLIExecutionJob {
	let process: SpawnedProcess
	private let stdoutReader = ProcessPipeReader()
	private let stderrReader = ProcessPipeReader()
	private var stdout = Data()
	private var stderr = Data()
	private var stdoutEOF = false
	private var stderrEOF = false
	private var acceptingOutput = true
	private var cancelled = false
	private var waiter: Task<(Int32, Bool), Error>?
	private var drainContinuation: CheckedContinuation<Void, Never>?
	private var drainTimeout: Task<Void, Never>?
	private var completed = false
	private var completionWaiters: [CheckedContinuation<Void, Never>] = []

	init(_ process: SpawnedProcess) { self.process = process }
	func cancel() { cancelled = true; waiter?.cancel() }
	func awaitCleanup() async {
		if completed { return }
		await withCheckedContinuation { completionWaiters.append($0) }
	}
	func markCompleted() {
		completed = true
		let pending = completionWaiters; completionWaiters.removeAll()
		for continuation in pending { continuation.resume() }
	}

	func execute(config: AgentCLIConfiguration, host: AgentCLIRunner.HostServices,
		stdin: String?, timeout: TimeInterval?, stream: AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.Continuation?) async throws -> AgentCLIRunner.Result {
		if Task.isCancelled { cancelled = true }
		let pid = process.pid
		let policy = host.terminationPolicy()
		let diagnostics = host.diagnostics
		let waitTask = Task.detached { () throws -> (Int32, Bool) in
			do {
				let result = try await ProcessTermination.waitForTermination(pid: pid, timeout: timeout, policy: policy, logger: diagnostics)
				return (result.exitCode, result.timedOut)
			} catch let error as ProcessTerminationError {
				switch error { case .waitFailed(let message): throw AgentCLIExecutionError.waitFailed(message) }
			}
		}
		waiter = waitTask
		if cancelled { waitTask.cancel() }
		var inputTask: Task<Void, Never>?
		let stopInput = InputStop()
		var reaped = false
		do {
			try stdoutReader.start(handle: process.stdout, label: "CLI stdout", preflight: host.readPreflight,
				onChunk: { [weak self] chunk in
					await self?.receive(chunk, stdout: true, config: config, stream: stream)
				}, onEOF: { [weak self] in await self?.eof(stdout: true) })
			try stderrReader.start(handle: process.stderr, label: "CLI stderr", preflight: host.readPreflight,
				onChunk: { [weak self] chunk in
					await self?.receive(chunk, stdout: false, config: config, stream: stream)
				}, onEOF: { [weak self] in await self?.eof(stdout: false) })
			if let stdin, !stdin.isEmpty, let input = process.stdin, let data = stdin.data(using: .utf8) {
				if config.logStdinSampleBytes > 0,
					let (sample, truncated) = makeUTF8Sample(from: data, limit: config.logStdinSampleBytes) {
					config.logCollector?.appendSection(title: "STDIN (sample)", content: sample + (truncated ? "…" : ""))
				}
				inputTask = Task.detached {
					defer { input.closeFile() }
					let fd = input.fileDescriptor
					_ = FDWriteSupport.configureNoSigPipe(fd: fd)
					// A broken pipe/early exit stops input, matching the prior runner.
					// So does the child being reaped: a descendant that inherited the
					// read end must not hold the write (and this runner) forever.
					Self.writeAll(data, to: fd, stop: stopInput)
				}
			} else { process.stdin?.closeFile() }
			let result = try await waitTask.value
			reaped = true
			// EOF callbacks follow every queued chunk; do not close readable FDs
			// before the FIFO consumer has drained. Descendant-held pipes are bounded.
			await drain()
			stopInput.stop()
			await inputTask?.value
			closeOutput()
			if !stdout.isEmpty { config.logCollector?.appendDataSection(title: "STDOUT", data: stdout) }
			if !stderr.isEmpty { config.logCollector?.appendDataSection(title: "STDERR", data: stderr) }
			return .init(stdout: stdout, stderr: stderr, status: result.0, timedOut: result.1)
		} catch {
			waitTask.cancel()
			if !reaped {
				do { _ = try await waitTask.value }
				catch {
					// The same lifecycle owner handles an exceptional waiter failure.
					_ = await ProcessTermination.terminateAndReap(pid: pid, policy: policy, logger: diagnostics)
				}
			}
			stopInput.stop()
			await inputTask?.value
			if inputTask == nil { process.stdin?.closeFile() }
			closeOutput()
			throw error
		}
	}

	/// Tells the stdin writer to give up once the child has been reaped.
	final class InputStop: Sendable {
		private let stopped = Mutex(false)
		func stop() { stopped.withLock { $0 = true } }
		var isStopped: Bool { stopped.withLock { $0 } }
	}

	/// Writes `data` to the child's stdin until it is all written, the pipe
	/// breaks, or `stop` is raised. The descriptor is switched to non-blocking
	/// and polled, so a reader that never drains the pipe cannot block the
	/// writer past `stop`.
	static func writeAll(_ data: Data, to fd: Int32, stop: InputStop) {
		guard fd >= 0, !data.isEmpty else { return }
		let flags = fcntl(fd, F_GETFL)
		guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
			try? FDWriteSupport.writeAll(data, to: fd)
			return
		}
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			var offset = 0
			while offset < raw.count {
				if stop.isStopped { return }
				let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
				if written > 0 { offset += written; continue }
				if written == 0 { return }
				switch errno {
				case EINTR: continue
				case EAGAIN:
					var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
					_ = poll(&descriptor, 1, 50)
				default: return // EPIPE, EBADF, ...: input stops, as before
				}
			}
		}
	}

	private func receive(_ data: Data, stdout isStdout: Bool, config: AgentCLIConfiguration,
		stream: AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.Continuation?) {
		guard acceptingOutput else { return }
		if isStdout {
			if stream == nil { stdout.append(data) } else { appendTail(&stdout, chunk: data, limit: config.captureStdoutTailBytes) }
			stream?.yield(.stdout(data))
		} else {
			if stream == nil { stderr.append(data) } else { appendTail(&stderr, chunk: data, limit: config.captureStderrTailBytes) }
			stream?.yield(.stderr(data))
		}
	}
	private func eof(stdout isStdout: Bool) {
		if isStdout { stdoutEOF = true } else { stderrEOF = true }
		if stdoutEOF && stderrEOF { finishDrain() }
	}
	private func drain() async {
		if stdoutEOF && stderrEOF { return }
		await withCheckedContinuation { continuation in
			drainContinuation = continuation
			drainTimeout = Task.detached { [weak self] in
				do { try await Task.sleep(for: .seconds(5)) } catch { return }
				await self?.forceDrain()
			}
		}
	}
	private func forceDrain() {
		acceptingOutput = false
		stdoutReader.cancel(); stderrReader.cancel()
		finishDrain()
	}
	private func finishDrain() {
		drainTimeout?.cancel(); drainTimeout = nil
		let continuation = drainContinuation; drainContinuation = nil
		continuation?.resume()
	}
	private func closeOutput() {
		acceptingOutput = false
		stdoutReader.cancel(); stderrReader.cancel()
		process.stdout.closeFile(); process.stderr.closeFile()
		waiter = nil
	}
}
