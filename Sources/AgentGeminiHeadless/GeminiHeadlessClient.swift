import Foundation
import AIClientKit
import AgentCLIExecution
import AgentHeadlessContracts
import ProcessStreamFraming

public actor GeminiHeadlessClient: HeadlessAgentProviding {
	private struct Active {
		let token: UUID
		let task: Task<Void, Never>
		let continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
	}
	private let host: GeminiHeadlessHostServices
	private let enableDebugLogging: Bool
	private let timeout: TimeInterval?
	private var latestClaim = UUID()
	private var active: Active?
	private var retiring: [UUID: Task<Void, Never>] = [:]

	public init(host: GeminiHeadlessHostServices, enableDebugLogging: Bool = false, timeout: TimeInterval? = 6000) {
        self.host = host; self.enableDebugLogging = enableDebugLogging; self.timeout = timeout
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
            try Task.checkCancellation()
            let context = try await host.prepare(message, requestedRunID)
            do {
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    try await attempt(context, token: token, continuation: continuation)
                } onCancel: { Task { await context.execution.cancelAll() } }
            } catch {
                await context.execution.cancelAll(); await host.cleanup(context)
                throw error
            }
            await context.execution.cancelAll(); await host.cleanup(context)
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch { continuation.finish(throwing: mapError(error)) }
    }

    private func attempt(_ context: GeminiHeadlessRunContext, token: UUID,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) async throws {
        let stream = try await context.execution.runStreaming(args: context.arguments, stdin: context.input,
            outputMode: .auto(.streamJson), timeout: timeout, additionalEnvironment: context.additionalEnvironment,
            additionalRemovedKeys: context.additionalRemovedKeys)
        try Task.checkCancellation()
        await host.startObservation(context) { [weak self] result in
            Task { await self?.deliver(result, token: token, to: continuation) }
        }
        var parser = GeminiHeadlessEventParser(runID: context.runID, enableDebugLogging: enableDebugLogging, diagnostics: host.diagnostics)
        var framer = LineFramer(); var stdoutTail = Data(); var stderrTail = Data()
        var status: Int32?; var timedOut = false; var completed = false
        func emitLine(_ line: Data) throws {
            guard !completed else { return }
            let values: [GeminiHeadlessEvent]
            do { values = try parser.parseStreamEvents(line) }
            catch let error as GeminiHeadlessParserError { throw error }
            catch { throw GeminiHeadlessParserError.runtime(error.localizedDescription) }
            for event in values {
                let result = event.streamResult
                guard !completed else { break }
                if result.type == "message_stop" { completed = true }
                deliver(result, token: token, to: continuation)
            }
        }
        outer: for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .stdout(let chunk):
                appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
                var lines: [Data] = []
                framer.feed(chunk) { lines.append($0) }
                for line in lines { try emitLine(line) }
                if completed { break outer }
            case .stderr(let chunk):
                appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
                if let text = String(data: chunk, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    deliver(.init(type: "system", text: text), token: token, to: continuation)
                }
            case .terminated(let code, let didTimeout): status = code; timedOut = didTimeout
            }
        }
        try Task.checkCancellation()
        var lines: [Data] = []; framer.flush { lines.append($0) }
        for line in lines { try emitLine(line) }
        if completed, status == nil { await context.execution.cancelAll() }
        guard status != nil || completed else {
            throw AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Gemini CLI did not report a termination status."]))
        }
        let code = status ?? 0
        if code != 0 || timedOut {
            if let detail = parser.extractCLIErrorDetail(fromStdout: stdoutTail) {
                throw AIProviderError.invalidConfiguration(detail: detail)
            }
            throw mapProcessFailure(exitCode: code, stderr: String(data: stderrTail, encoding: .utf8) ?? "", timedOut: timedOut)
        }
        if !completed { deliver(.init(type: "message_stop", text: nil), token: token, to: continuation) }
        if enableDebugLogging { host.diagnostics("[DEBUG] GeminiAgent: Stream completed successfully") }
    }
	private func mapError(_ error: Error) -> Error {
		if let parserError = error as? GeminiHeadlessParserError {
			if case .runtime(let detail) = parserError { return AIProviderError.invalidConfiguration(detail: detail) }
		}
		if let runnerError = error as? AgentCLIExecutionError {
			switch runnerError {
			case .commandNotFound(let command):
				return AIProviderError.invalidConfiguration(detail: "Gemini CLI not found (\(command)). Install it and ensure it is available on PATH.")
			case .spawnFailed(let message):
				return AIProviderError.invalidConfiguration(detail: message)
			default:
				return runnerError
			}
		}
		return error
	}

	private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool) -> Error {
		if timedOut {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI timed out. Please retry shortly.")
		}
		let lower = stderr.lowercased()
		if lower.contains("command not found") || lower.contains("no such file") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI not found. Install it and ensure it is available on PATH.")
		}
		if lower.contains("not logged in") || lower.contains("login") || lower.contains("unauthorized") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI not authenticated. Run `gemini login` in a terminal and try again.")
		}
		if lower.contains("rate limit") || lower.contains("too many requests") {
			return AIProviderError.invalidConfiguration(detail: "Gemini CLI rate limited. Please wait and retry.")
		}
		if exitCode == 148 {
			return AIProviderError.invalidConfiguration(detail: stderr.isEmpty ? "Gemini CLI reported an API error (exit code 148)." : stderr)
		}
		if stderr.isEmpty {
			return AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "Gemini CLI exited with status \(exitCode)"]))
		}
		return AIProviderError.apiError(source: NSError(domain: "GeminiCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr]))
	}


}
