import Foundation
import AIClientKit
import ClaudeRuntimeKit

/// Lossless evidence, compatibility results, normalized events, and redacted
/// diagnostics stay together. Hosts select projection authority and storage.
public struct ClaudeNativeTranslationBatch: Sendable {
	public let envelope: ClaudeEventEnvelope
	public let results: [AIStreamResult]
	public let diagnostics: [ClaudeRuntimeDiagnostic]
	public let normalizedEvents: [ClaudeRuntimeEvent]
	public init(envelope: ClaudeEventEnvelope, results: [AIStreamResult], diagnostics: [ClaudeRuntimeDiagnostic], normalizedEvents: [ClaudeRuntimeEvent]) {
		self.envelope = envelope
		self.results = results
		self.diagnostics = diagnostics
		self.normalizedEvents = normalizedEvents
	}
}

/// Tool inventory, status ownership, and diagnostics are host policy. The
/// translator itself performs no logging-file, preference, or bundle lookup.
public struct ClaudeTranslatorPolicy: Sendable {
	public let isExternallyTrackedTool: @Sendable (String) -> Bool
	public let reasoningEnabled: Bool
	public let diagnostics: @Sendable (String) -> Void
	public let reasoningDiagnostics: @Sendable (String) -> Void
	public init(
		isExternallyTrackedTool: @escaping @Sendable (String) -> Bool,
		reasoningEnabled: Bool,
		diagnostics: @escaping @Sendable (String) -> Void,
		reasoningDiagnostics: @escaping @Sendable (String) -> Void
	) {
		self.isExternallyTrackedTool = isExternallyTrackedTool
		self.reasoningEnabled = reasoningEnabled
		self.diagnostics = diagnostics
		self.reasoningDiagnostics = reasoningDiagnostics
	}
}
