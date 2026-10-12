import Foundation
import AgentRuntimeKit

public struct AgentTranscriptHistoricalTextPolicy {
	private let truncate: (String, Int, String) -> String
	public init(truncate: @escaping (String, Int, String) -> String) { self.truncate = truncate }

	// MARK: - Configuration

	/// Maximum estimated tokens for a single eligible text field before truncation kicks in.
	public static let maxFieldTokens = 10_000

	/// Number of most-recent turns (by turn order) that are exempt from truncation.
	public static let recentTurnExemptionCount = 3

	/// Marker inserted at the truncation point.
	public static let truncationMarker = "\n\n[content truncated]\n\n"

	// MARK: - Transcript-Level API

	/// Returns a copy of `transcript` with eligible old-turn text fields middle-truncated.
	///
	/// - Parameter transcript: The transcript to reduce. This policy only rewrites eligible
	///   text fields; it intentionally leaves structured tool payload JSON untouched.
	/// - Parameter exemptTurnCount: Override for the number of recent turns to exempt.
	///   Defaults to `Self.recentTurnExemptionCount`.
	public func truncatedTranscript(
		_ transcript: AgentTranscript,
		exemptTurnCount: Int? = nil
	) -> AgentTranscript {
		let exemptCount = max(0, exemptTurnCount ?? Self.recentTurnExemptionCount)
		let turnCount = transcript.turns.count
		guard turnCount > exemptCount else { return transcript }

		var copy = transcript
		let eligibleEnd = turnCount - exemptCount
		for index in 0..<eligibleEnd {
			truncateTurnFields(&copy.turns[index])
		}
		return copy
	}

	/// Returns a copy of `turns` (an exported slice) with eligible old-turn text fields
	/// middle-truncated. Recency is computed relative to the **slice**, not the full transcript.
	///
	/// Used by handoff export where the exported range may be a subset of the full transcript.
	public func truncatedExportSlice(
		_ turns: [AgentTranscriptTurn],
		exemptTurnCount: Int? = nil
	) -> [AgentTranscriptTurn] {
		let exemptCount = max(0, exemptTurnCount ?? Self.recentTurnExemptionCount)
		guard turns.count > exemptCount else { return turns }

		var copy = turns
		let eligibleEnd = turns.count - exemptCount
		for index in 0..<eligibleEnd {
			truncateTurnFields(&copy[index])
		}
		return copy
	}

	// MARK: - Simulated Byte Count (for compactor)

	/// Estimate the retained-detail bytes for a transcript *as if* historical truncation
	/// had already been applied. This lets the compactor make tier decisions against a
	/// reduced representation without mutating the live transcript.
	public func simulatedRetainedFullDetailBytes(
		for transcript: AgentTranscript,
		exemptTurnCount: Int? = nil
	) -> Int {
		let exemptCount = max(0, exemptTurnCount ?? Self.recentTurnExemptionCount)
		let turnCount = transcript.turns.count
		let eligibleEnd = max(0, turnCount - exemptCount)

		return transcript.turns.enumerated().reduce(into: 0) { partial, pair in
			let (index, turn) = pair
			guard turn.retentionTier == .full else { return }
			if index < eligibleEnd {
				partial += simulatedRetainedDetailBytes(for: turn)
			} else {
				partial += retainedDetailBytes(for: turn)
			}
		}
	}

	// MARK: - Turn-Level Mutation

	/// Truncates eligible text fields on a single turn in-place.
	private func truncateTurnFields(_ turn: inout AgentTranscriptTurn) {
		// Truncate activities in each response span.
		for spanIndex in turn.responseSpans.indices {
			for activityIndex in turn.responseSpans[spanIndex].activities.indices {
				truncateActivity(&turn.responseSpans[spanIndex].activities[activityIndex])
			}
		}

		// Truncate summary fields on already-compacted turns that only have summaries.
		if var summary = turn.summary {
			truncateSummary(&summary)
			turn.summary = summary
		}
	}

	/// Truncates eligible text fields on a single activity in-place.
	///
	/// Safe candidates:
	/// - `.assistant` / `.assistantInline` / `.toolResult` activity text
	/// - `.reasoning` text
	///
	/// Explicit non-candidates (left untouched):
	/// - User messages (`.user` kind)
	/// - `toolExecution.argsJSON` (structured, parsed downstream)
	/// - `toolExecution.resultJSON` (structured — sanitized by AgentToolResultPersistencePolicy)
	private func truncateActivity(_ activity: inout AgentTranscriptActivity) {
		switch activity.itemKind {
		case .assistant, .assistantInline, .toolResult:
			activity.text = truncate(activity.text, Self.maxFieldTokens, Self.truncationMarker)
		case .user, .toolCall, .system, .error, .thinking:
			break
		}

		if let reasoning = activity.reasoning {
			activity.reasoning = truncate(reasoning, Self.maxFieldTokens, Self.truncationMarker)
		}
	}

	/// Truncates summary text fields for already-compacted turns.
	private func truncateSummary(_ summary: inout AgentTranscriptTurnSummary) {
		if let text = summary.middleSummaryText {
			summary.middleSummaryText = truncate(text, Self.maxFieldTokens, Self.truncationMarker)
		}
		if let text = summary.conclusionText {
			summary.conclusionText = truncate(text, Self.maxFieldTokens, Self.truncationMarker)
		}
		if let text = summary.compactConclusionText {
			summary.compactConclusionText = truncate(text, Self.maxFieldTokens, Self.truncationMarker)
		}
	}

	// MARK: - Byte Estimation Helpers

	/// Actual retained detail bytes for a turn (mirrors `AgentTranscriptCompactor.retainedDetailBytes`).
	private func retainedDetailBytes(for turn: AgentTranscriptTurn) -> Int {
		turn.allActivities.reduce(into: 0) { partial, activity in
			partial += activity.text.utf8.count
			partial += (activity.reasoning ?? "").utf8.count
			guard let execution = activity.toolExecution else { return }
			partial += (execution.argsJSON ?? "").utf8.count
			let resultJSON = execution.resultJSON ?? ""
			if resultJSON != activity.text {
				partial += resultJSON.utf8.count
			}
			partial += (execution.summaryText ?? "").utf8.count
		}
	}

	/// Simulated retained detail bytes for a turn, as if truncation had been applied to
	/// eligible text fields. Non-text fields (argsJSON, resultJSON) are counted at actual size
	/// since they are not truncated here.
	private func simulatedRetainedDetailBytes(for turn: AgentTranscriptTurn) -> Int {
		let cap = Self.maxFieldTokens * 4 // byte budget corresponding to the token cap
		return turn.allActivities.reduce(into: 0) { partial, activity in
			switch activity.itemKind {
			case .assistant, .assistantInline, .toolResult:
				partial += min(activity.text.utf8.count, cap)
			default:
				partial += activity.text.utf8.count
			}
			if let reasoning = activity.reasoning {
				partial += min(reasoning.utf8.count, cap)
			}
			guard let execution = activity.toolExecution else { return }
			partial += (execution.argsJSON ?? "").utf8.count
			let resultJSON = execution.resultJSON ?? ""
			if resultJSON != activity.text {
				partial += resultJSON.utf8.count
			}
			partial += (execution.summaryText ?? "").utf8.count
		}
	}
}
