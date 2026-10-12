import Foundation
import AgentRuntimeKit

/// Provider-specific projections of persisted usage. No model-preference lookup or I/O.
public enum AgentUsageRestoration {
    public enum Provider: Sendable, CaseIterable { case claude, gemini, openCode, passthrough }

    /// Reopen policy retains exact restored Claude readings and native/provider-opaque
    /// context, while reconstructing Gemini/OpenCode from their durable turn rows.
    public static func restore(for provider: Provider, tokens: [AgentTokenUsagePersist], existing: AgentContextUsage?) -> AgentContextUsage? {
        switch provider {
        case .claude:
            if existing?.lastTotalTokens != nil { return existing }
            return claude(tokens, modelContextWindow: existing?.modelContextWindow)
        case .gemini: return gemini(tokens, modelContextWindow: existing?.modelContextWindow)
        case .openCode: return openCode(tokens, modelContextWindow: existing?.modelContextWindow)
        case .passthrough: return existing
        }
    }

	public static func claude(
		_ usage: [AgentTokenUsagePersist],
		modelContextWindow: Int?
	) -> AgentContextUsage? {
		guard !usage.isEmpty else { return nil }
		let defaultClaudeContextWindow = 200_000
		let maxContextTokens = max(1, modelContextWindow ?? defaultClaudeContextWindow)
		// Only trust exact stream-derived context snapshots (contextUsedTokens).
		// Do NOT fall back to promptTokens — those are billed-turn aggregates that
		// include internal tool sub-steps and cause inflated context estimates.
		let latestContextUsed = usage.reversed().compactMap { turn -> Int? in
			if let contextUsed = turn.contextUsedTokens,
				contextUsed > 0,
				contextUsed <= maxContextTokens {
				return contextUsed
			}
			return nil
		}.first
		if let latestContextUsed {
			return AgentContextUsage(
				modelContextWindow: modelContextWindow,
				lastTotalTokens: latestContextUsed,
				totalTotalTokens: latestContextUsed
			)
		}
		guard modelContextWindow != nil else { return nil }
		return AgentContextUsage(
			modelContextWindow: modelContextWindow,
			lastTotalTokens: nil,
			totalTotalTokens: nil
		)
	}

	/// OpenCode restores context from the LATEST absolute reading, never from a sum
	/// (tenth round, finding 3). `used` is the session's current context occupancy, so
	/// adding turns together would report a number that describes nothing. Prompt +
	/// completion is a last-resort signal for a turn that carried no absolute reading.
	/// A retention SUMMARY row is typed (twelfth round, finding 2): its aggregate
	/// prompt+completion describes many dropped turns, so the reversed scan reads only
	/// the latest-dropped evidence the summary preserved — never the aggregate.
	public static func openCode(
		_ usage: [AgentTokenUsagePersist],
		modelContextWindow: Int?
	) -> AgentContextUsage? {
		guard !usage.isEmpty else { return nil }
		// `openCodeLatestReading` applies OpenCode's per-row rule (context-first,
		// provider-total-second) to real rows AND reproduces it over a summary's dropped
		// block (thirteenth round, finding 3 — the twelfth round stored only a provider
		// total, so a dropped block ending in a context-bearing turn restored the wrong
		// number; the reversed scan now reads the correct per-row reading either way).
		let latest = usage.reversed().compactMap(\.openCodeLatestReading).first
		guard let latest else {
			guard modelContextWindow != nil else { return nil }
			return AgentContextUsage(
				modelContextWindow: modelContextWindow,
				lastTotalTokens: nil,
				totalTotalTokens: nil
			)
		}
		return AgentContextUsage(
			modelContextWindow: modelContextWindow,
			lastTotalTokens: latest,
			totalTotalTokens: latest
		)
	}

	public static func gemini(
		_ usage: [AgentTokenUsagePersist],
		modelContextWindow: Int?
	) -> AgentContextUsage? {
		guard !usage.isEmpty else { return nil }
		// A summary row contributes the WHOLE dropped block's cumulative sum to the total
		// (preserving estimated-input-only dropped turns the twelfth round's
		// prompt/completion-only aggregate lost), and its LAST real dropped turn's total to
		// `lastTotalTokens` — never its aggregate (thirteenth round, finding 3). A real row
		// contributes its own turn total to both.
		var cumulativeParts: [Int] = []
		var lastReading: Int?
		for turn in usage {
			if let cumulative = turn.geminiCumulativeContribution {
				cumulativeParts.append(cumulative)
			}
			if let reading = turn.geminiLatestTurnTotal {
				lastReading = reading
			}
		}
		if cumulativeParts.isEmpty, lastReading == nil {
			guard modelContextWindow != nil else { return nil }
			return AgentContextUsage(
				modelContextWindow: modelContextWindow,
				lastTotalTokens: nil,
				totalTotalTokens: nil
			)
		}
		// Overflow-safe reduction (tenth round, finding 7): an unbounded number of
		// persisted turns must not be able to trap the host in a cumulative sum.
		return AgentContextUsage(
			modelContextWindow: modelContextWindow,
			lastTotalTokens: lastReading,
			totalTotalTokens: AgentTokenUsagePersist.clampedSum(cumulativeParts)
		)
	}
}
