import Foundation
import Darwin
import ProcessKit

public final class AgentCLIRunner: Sendable {
	public struct Result: Sendable {
		public let stdout: Data
		public let stderr: Data
		public let status: Int32
		public let timedOut: Bool
		public init(stdout: Data, stderr: Data, status: Int32, timedOut: Bool) {
			self.stdout = stdout; self.stderr = stderr; self.status = status; self.timedOut = timedOut
		}
	}
	public enum OutputFlagMode: Sendable { case auto(AgentCLIOutputFormat), none, custom([String]) }
	public enum StreamEvent: Sendable { case stdout(Data), stderr(Data), terminated(status: Int32, timedOut: Bool) }
	public let config: AgentCLIConfiguration
	private let host: HostServices
	private let registry = CLIExecutionRegistry()
	private let gate: CLIExecutionGate
	public init(config: AgentCLIConfiguration, host: HostServices, concurrencyLimit: Int = 1) {
		self.config = config; self.host = host; gate = CLIExecutionGate(concurrencyLimit)
	}

	private struct Started: Sendable { let id: UUID; let job: CLIExecutionJob; let command: String; let pid: Int32 }
	private func start(args: [String], mode: OutputFlagMode, additionalEnvironment: [String: String], removedKeys: Set<String>) async throws -> Started {
		let generation = await registry.currentGeneration()
		try await gate.acquire()
		do {
			try Task.checkCancellation()
			let environment = try await host.environment(config, additionalEnvironment, removedKeys)
			try Task.checkCancellation()
			let command = try await host.resolveCommand(config, environment)
			try Task.checkCancellation()
			let directory = host.expandWorkingDirectory(config.workingDirectory, environment)
			log("Using working directory: \(directory)")
			var arguments = config.commandSuffix + args
			Self.applyOutputMode(&arguments, outputMode: mode)
			var isDirectory: ObjCBool = false
			if command.contains("/"), FileManager.default.fileExists(atPath: command, isDirectory: &isDirectory), isDirectory.boolValue {
				throw AgentCLIExecutionError.commandNotFound(command)
			}
			log(config.enableDebugLogging ? "Launching \(command) with arguments: \(Self.sanitizedLaunchArguments(arguments))" : "Launching \(command)")
			try Task.checkCancellation()
			let started: (UUID, CLIExecutionJob, Int32)
			do { started = try await registry.spawn(command: command, arguments: arguments, environment: environment, directory: directory, expectedGeneration: generation) }
			catch let error as ProcessLauncherError { throw mapLauncherError(error, command: command, workingDirectory: directory) }
			await host.didStart(started.0, started.2)
			return .init(id: started.0, job: started.1, command: command, pid: started.2)
		} catch {
			await gate.release()
			throw error
		}
	}
	private func finish(_ started: Started, result: Result?) async {
		if let result {
			log("Process \(started.pid) exited with status \(result.status) (timed out: \(result.timedOut))")
			if result.status == 0, !result.timedOut, started.command.contains("/"), access(started.command, X_OK) == 0 {
				await host.rememberSuccessfulCommand(config.command, started.command)
			}
		}
		await host.didFinish(started.id, started.pid)
		await registry.remove(started.id)
		await gate.release()
		await started.job.markCompleted()
	}

	public func run(args: [String], stdin: String?, outputMode: OutputFlagMode = .auto(.json), timeout: TimeInterval?,
		additionalEnvironment: [String: String] = [:], additionalRemovedKeys: Set<String> = []) async throws -> Result {
		let started = try await start(args: args, mode: outputMode, additionalEnvironment: additionalEnvironment, removedKeys: additionalRemovedKeys)
		let result: Result
		do {
			result = try await withTaskCancellationHandler {
				try await started.job.execute(config: config, host: host, stdin: stdin, timeout: timeout, stream: nil)
			} onCancel: { Task { await started.job.cancel() } }
		} catch {
			await finish(started, result: nil)
			throw error
		}
		await finish(started, result: result)
		try Task.checkCancellation()
		return result
	}
	public func runStreaming(args: [String], stdin: String?, outputMode: OutputFlagMode = .auto(.streamJson), timeout: TimeInterval?,
		additionalEnvironment: [String: String] = [:], additionalRemovedKeys: Set<String> = []) async throws -> AsyncThrowingStream<StreamEvent, Error> {
		let started = try await start(args: args, mode: outputMode, additionalEnvironment: additionalEnvironment, removedKeys: additionalRemovedKeys)
		if Task.isCancelled { await started.job.cancel() }
		return AsyncThrowingStream { continuation in
			Task {
				do {
					let result = try await started.job.execute(config: config, host: host, stdin: stdin, timeout: timeout, stream: continuation)
					await finish(started, result: result)
					continuation.yield(.terminated(status: result.status, timedOut: result.timedOut))
					continuation.finish()
				} catch {
					await finish(started, result: nil)
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { reason in
				if case .cancelled = reason { Task { await started.job.cancel() } }
			}
		}
	}
	public func cancelAll() async {
		let jobs = await registry.cancelGeneration()
		await gate.cancelQueued()
		for job in jobs { await job.cancel() }
		for job in jobs { await job.awaitCleanup() }
	}
	private func log(_ message: String) {
		config.logCollector?.append(message)
		if config.enableDebugLogging { host.diagnostics("[CLIProcessRunner] \(message)") }
	}
}
