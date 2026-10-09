import AIClientKit

public enum GeminiHeadlessEvent: Sendable, Equatable {
    case initialized
    case message(content: String)
    case toolCall(name: String, argumentsJSON: String)
    case toolResult(name: String, result: String)
    case completion(inputTokens: Int?, outputTokens: Int?, providerSessionID: String?)

    /// Preserve the headless CLI's historical presentation. Concrete MCP tools
    /// are observed through the host's tracking service.
    public var streamResult: AIStreamResult {
        switch self {
        case .initialized: return .init(type: AIStreamResult.lifecycleType, text: "initialized")
        case .message(let content): return .init(type: "content", text: content)
        case .toolCall(let name, _): return .init(type: "event", text: "Using tool: \(name)")
        case .toolResult(let name, let result): return .init(type: "event", text: "Tool \(name) completed: \(result)")
        case .completion(let input, let output, let session):
            return .init(type: "message_stop", text: nil, promptTokens: input, completionTokens: output, providerSessionID: session)
        }
    }
}
