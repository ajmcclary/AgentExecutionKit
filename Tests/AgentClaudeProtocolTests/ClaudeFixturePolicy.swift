import AgentClaudeProtocol

typealias ClaudeSDKNDJSONTranslator = ClaudeNativeEventTranslator
typealias ClaudeTranslationBatch = ClaudeNativeTranslationBatch

extension ClaudeNativeEventTranslator {
	init(enableDebugLogging: Bool = false, reasoningEnabled: Bool = false) {
		self.init(enableDebugLogging: enableDebugLogging, policy: .init(
			isExternallyTrackedTool: { $0 == "mcp__RepoPrompt__read_file" },
			reasoningEnabled: reasoningEnabled, diagnostics: { _ in }, reasoningDiagnostics: { _ in }))
	}
}
