import Foundation
import AgentRuntimeKit

public enum ContextUsageSnapshotSource: String, Codable, Equatable, Sendable {
	case claudeUsageEvent
	case geminiUsageEvent
	case openCodeUsageEvent
	case codexNativeUsage
	case turnFinalization
	case persistedTurns
	case compactionSignal
}

public enum ContextUsageSnapshotConfidence: String, Codable, Equatable, Sendable {
	case exact
	case bestEffort
	case inferred
}

public struct ContextUsageSnapshot: Codable, Equatable, Sendable {
	public var used: Int?
	public var window: Int?
	public var confidence: ContextUsageSnapshotConfidence
	public var source: ContextUsageSnapshotSource
	public var compactedAt: Date?

	public init(used: Int?, window: Int?, confidence: ContextUsageSnapshotConfidence, source: ContextUsageSnapshotSource, compactedAt: Date? = nil) {
		self.used = used; self.window = window; self.confidence = confidence; self.source = source; self.compactedAt = compactedAt
	}
}

public extension ContextUsageSnapshot {
	static func fromAgentContextUsage(
		_ usage: AgentContextUsage?,
		source: ContextUsageSnapshotSource,
		confidence: ContextUsageSnapshotConfidence,
		compactedAt: Date? = nil
	) -> ContextUsageSnapshot? {
		let used = usage?.lastTotalTokens
		let window = usage?.modelContextWindow
		guard used != nil || window != nil || compactedAt != nil else { return nil }
		return ContextUsageSnapshot(
			used: used,
			window: window,
			confidence: confidence,
			source: source,
			compactedAt: compactedAt
		)
	}
}

