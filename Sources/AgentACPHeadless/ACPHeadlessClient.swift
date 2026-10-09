import Foundation
import AIClientKit
import AgentRuntimeKit
import AgentHeadlessContracts

public actor ACPHeadlessClient: HeadlessAgentProviding {
	private struct Active {
		let token: UUID
		let task: Task<Void, Never>
		let continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
	}
    public enum ApprovalPolicy: Sendable { case declineUnsupported, acceptForSession }
    public typealias Prepare = @Sendable (HeadlessAgentMessage, UUID) async throws -> ACPHeadlessControllerServices
    private let providerName: String
    private let prepare: Prepare
    private let approvalPolicy: ApprovalPolicy
	private var latestClaim = UUID()
	private var active: Active?
	private var retiring: [UUID: Task<Void, Never>] = [:]

    public init(providerName: String, prepare: @escaping Prepare, approvalPolicy: ApprovalPolicy) {
        self.providerName = providerName; self.prepare = prepare; self.approvalPolicy = approvalPolicy
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
            let controller = try await prepare(message, requestedRunID ?? UUID())
            let cleanup = Cleanup(controller)
            do {
                try Task.checkCancellation()
                try await withTaskCancellationHandler {
                    let forward = Task { try await forwardEvents(controller, token: token, continuation: continuation) }
                    do {
                        try await controller.bootstrapAndConfigure()
                        try Task.checkCancellation()
                        try await controller.prompt(message)
                        await cleanup.shutdown()
                        try await forward.value
                    } catch {
                        forward.cancel()
                        await cleanup.cancelAndShutdown()
                        _ = try? await forward.value
                        throw error
                    }
                } onCancel: { Task { await cleanup.cancelAndShutdown() } }
                await cleanup.shutdown()
                continuation.finish()
            } catch {
                await cleanup.cancelAndShutdown()
                if error is CancellationError { throw error }
                throw await controller.normalizeError(error)
            }
        } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
        catch { continuation.finish(throwing: error) }
    }
    private func forwardEvents(_ controller: ACPHeadlessControllerServices, token: UUID,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation) async throws {
        var terminalError: String?
        var completed = false
        for await event in controller.events {
            try Task.checkCancellation()
            guard latestClaim == token else { throw CancellationError() }
            switch event {
            case .stream(let result):
                if result.type == "message_stop" {
                    guard !completed else { continue }; completed = true
                }
                deliver(result, token: token, to: continuation)
            case .terminal(let state, let text):
                if state == .failed { terminalError = text ?? "\(providerName) ACP run failed." }
            case .approvalRequested(let request):
                switch approvalPolicy {
                case .acceptForSession: await controller.respond(request.requestID, .acceptForSession)
                case .declineUnsupported:
                    let reason = request.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = reason.isEmpty
                        ? "\(providerName) requested tool approval, which is not supported in headless discovery runs."
                        : "\(providerName) requested tool approval during headless discovery: \(reason)"
                    await controller.respond(request.requestID, .decline)
                    await controller.cancelPrompt()
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: detail))
                    return
                }
            case .approvalCancelled, .approvalResolved: break
            }
        }
        try Task.checkCancellation()
        if let terminalError { continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: terminalError)) }
    }
    private actor Cleanup {
        let controller: ACPHeadlessControllerServices
        var cancellation: Task<Void, Never>?
        var shutdownTask: Task<Void, Never>?
        init(_ controller: ACPHeadlessControllerServices) { self.controller = controller }
        func shutdown() async {
            if shutdownTask == nil { shutdownTask = Task { await controller.shutdown() } }
            await shutdownTask?.value
        }
        func cancelAndShutdown() async {
            if cancellation == nil { cancellation = Task { await controller.cancelPrompt() } }
            await cancellation?.value
            await shutdown()
        }
    }
}
