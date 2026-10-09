import Foundation
import AIClientKit
import AgentCLIExecution
import AgentHeadlessContracts
import ProcessStreamFraming

public actor CodexExecClient: HeadlessAgentProviding {
	private struct Active {
		let token: UUID
		let task: Task<Void, Never>
		let continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
	}
	private let host: CodexExecHostServices
	private let toolPolicy: CodexExecToolPolicy
	private let enableDebugLogging: Bool
	private let timeout: TimeInterval?
	private var latestClaim = UUID()
	private var active: Active?
	private var retiring: [UUID: Task<Void, Never>] = [:]

	public init(host: CodexExecHostServices, toolPolicy: CodexExecToolPolicy, enableDebugLogging: Bool = false, timeout: TimeInterval? = 6000) {
		self.host = host; self.toolPolicy = toolPolicy; self.enableDebugLogging = enableDebugLogging; self.timeout = timeout
	}
	public func streamAgentMessage(_ message: HeadlessAgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		let claim = UUID(); latestClaim = claim
		retireActive()
		for task in Array(retiring.values) { await task.value }
		guard latestClaim == claim, !Task.isCancelled else { throw CancellationError() }
		return AsyncThrowingStream { continuation in
			let task = Task { await execute(message, requestedRunID: runID, token: claim, continuation: continuation) }
			active = .init(token: claim, task: task, continuation: continuation)
			continuation.onTermination = { [weak self] reason in
				guard case .cancelled = reason else { return }
				Task { await self?.cancel(claim) }
			}
		}
	}
	private func retireActive() {
		guard let active else { return }
		self.active = nil
		retiring[active.token] = active.task
		active.task.cancel()
		active.continuation.finish()
	}
	private func cancel(_ token: UUID) async {
		guard active?.token == token else { return }
		latestClaim = UUID(); retireActive()
		for task in Array(retiring.values) { await task.value }
	}
	public func dispose() async {
		latestClaim = UUID(); retireActive()
		for task in Array(retiring.values) { await task.value }
	}
	private func deliver(_ result: AIStreamResult, token: UUID, to continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) {
		guard latestClaim == token, !Task.isCancelled else { return }
		continuation.yield(result)
	}
	private func execute(_ message: HeadlessAgentMessage, requestedRunID: UUID?, token: UUID,
		continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) async {
		defer { if active?.token == token { active = nil }; retiring[token] = nil }
		do {
			try host.validate()
			var retriedBrokenServer = false
			for _ in 0..<2 {
				try Task.checkCancellation()
				let context = try await host.prepare(requestedRunID)
				let retry: String?
				do {
					try Task.checkCancellation()
					await host.startObservation(context) { [weak self] result in
						Task { await self?.deliver(result, token: token, to: continuation) }
					}
					try Task.checkCancellation()
					retry = try await withTaskCancellationHandler {
						try await attempt(message, context: context, token: token, continuation: continuation, didRetry: retriedBrokenServer)
					} onCancel: { Task { await context.execution.cancelAll() } }
				} catch {
					await context.execution.cancelAll(); await host.cleanup(context)
					throw error
				}
				await context.execution.cancelAll(); await host.cleanup(context)
				try Task.checkCancellation()
				if let retry {
					await host.recordBrokenServer(retry)
					retriedBrokenServer = true
					continue
				}
				continuation.finish(); return
			}
			continuation.finish()
		} catch is CancellationError {
			continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Codex Exec run cancelled."))
		} catch { continuation.finish(throwing: error) }
	}

	private func attempt(_ message: HeadlessAgentMessage, context: CodexExecRunContext, token: UUID,
		continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation, didRetry: Bool) async throws -> String? {
		let prompt = "\(message.systemPrompt)\n\n\(message.userMessage)"
		let stream = try await context.execution.runStreaming(args: context.arguments, stdin: prompt, outputMode: .none,
			timeout: timeout, additionalEnvironment: [:], additionalRemovedKeys: [])
		var parser = CodexExecEventParser(policy: toolPolicy)
		var stdoutFramer = LineFramer(); var stderrFramer = LineFramer()
		var stdoutTail = Data(); var stderrTail = Data()
		var status: Int32?; var timedOut = false; var completed = false
		func emit(_ result: AIStreamResult) {
			if result.type == "message_stop" {
				guard !completed else { return }; completed = true
			}
			deliver(result, token: token, to: continuation)
		}
		outer: for try await event in stream {
			try Task.checkCancellation()
			switch event {
			case .stdout(let chunk):
				appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
				var lines: [Data] = []
				stdoutFramer.feed(chunk) { lines.append($0) }
				for line in lines {
					guard !completed, let result = parser.parseJSONLEvent(line) else { continue }
					emit(result)
				}
				if completed { break outer }
			case .stderr(let chunk):
				appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
				var lines: [Data] = []
				stderrFramer.feed(chunk) { lines.append($0) }
				for line in lines {
					if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !CodexExecDiagnosticNoiseFilter.shouldSuppress(text) {
						emit(.init(type: "system", text: text))
					}
				}
			case .terminated(let code, let timeout): status = code; timedOut = timeout
			}
		}
		try Task.checkCancellation()
		if completed, status == nil { await context.execution.cancelAll() }
		var stdoutLines: [Data] = []; var stderrLines: [Data] = []
		stdoutFramer.flush { stdoutLines.append($0) }
		stderrFramer.flush { stderrLines.append($0) }
		for line in stdoutLines { if let result = parser.parseJSONLEvent(line) { emit(result) } }
		for line in stderrLines {
			if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !CodexExecDiagnosticNoiseFilter.shouldSuppress(text) { emit(.init(type: "system", text: text)) }
		}
		guard status != nil || completed else {
			throw AIProviderError.apiError(source: NSError(domain: "CodexCLI", code: -999, userInfo: [NSLocalizedDescriptionKey: "codex exec did not report a termination status."]))
		}
		let code = status ?? 0
		if code != 0 || timedOut {
			let detail = parser.extractCLIErrorDetail(fromStdout: stdoutTail)
			let stderr = String(data: stderrTail, encoding: .utf8) ?? ""
			if detail == nil, !didRetry, let server = CodexExecFailureClassifier.extractBrokenServerName(from: stderr) { return server }
			if let detail {
				if CodexExecFailureClassifier.isModelUnavailableErrorDetail(detail) { throw host.modelUnavailableError(detail) }
				throw AIProviderError.invalidConfiguration(detail: detail)
			}
			throw Self.processFailure(exitCode: code, stderr: stderr, timedOut: timedOut)
		}
		if !completed { emit(.init(type: "message_stop", text: nil)) }
		if enableDebugLogging { host.diagnostics("[DEBUG] CodexExec: Stream completed successfully") }
		return nil
	}
	private static func processFailure(exitCode: Int32, stderr: String, timedOut: Bool) -> any Error {
		if timedOut { return AIProviderError.invalidConfiguration(detail: "codex exec timed out. Please retry shortly.") }
		let lower = stderr.lowercased()
		if lower.contains("command not found") || lower.contains("no such file") { return AIProviderError.invalidConfiguration(detail: "Codex CLI not found. Install it and ensure it is available on PATH.") }
		if lower.contains("not authenticated") || lower.contains("unauthorized") { return AIProviderError.invalidConfiguration(detail: "Codex CLI not authenticated. Run `codex login` in a terminal and try again.") }
		if lower.contains("rate limit") || lower.contains("too many requests") { return AIProviderError.invalidConfiguration(detail: "Codex CLI rate limited. Please wait and try again.") }
		if lower.contains("overload") || lower.contains("busy") || lower.contains("unavailable") { return AIProviderError.invalidConfiguration(detail: "Codex CLI backend overloaded. Please retry soon.") }
		return AIProviderError.apiError(source: NSError(domain: "CodexCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "codex exec exited with status \(exitCode)" : stderr]))
	}
}
