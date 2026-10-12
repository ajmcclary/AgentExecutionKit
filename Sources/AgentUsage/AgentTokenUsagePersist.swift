import Foundation

public struct AgentTokenUsagePersist: Codable, Equatable, Sendable {
	/// Upper bound for any single persisted token count.
	///
	/// Tenth round, finding 7: decoding accepted any `Int`, including `Int.max`, from a
	/// file an agent process can influence. `providerTotalTokens`, `estimatedInputTokens`
	/// and cumulative usage reductions then performed
	/// UNCHECKED additions on those values, so two large persisted turns aborted the host
	/// on overflow. Bounding at the boundary makes every downstream sum provably safe:
	/// three bounded fields cannot exceed 3e12, and `clampedSum` keeps reductions over an
	/// unbounded number of turns inside the same bound.
	///
	/// A value outside the bound is not evidence of anything, so it is DROPPED to zero
	/// rather than clamped to the bound — clamping would fabricate a plausible total.
	public static let maxPersistedTokenCount = 1_000_000_000_000

	public static func boundedTokenCount(_ raw: Int) -> Int {
		guard raw > 0 else { return 0 }
		return raw <= maxPersistedTokenCount ? raw : 0
	}

	/// Addition that saturates at the bound instead of trapping.
	public static func clampedSum(_ values: [Int]) -> Int {
		values.reduce(0) { partial, value in
			let next = partial.addingReportingOverflow(max(0, value))
			guard !next.overflow else { return maxPersistedTokenCount }
			return min(next.partialValue, maxPersistedTokenCount)
		}
	}

	/// Maximum number of per-turn rows retained in `providerTokenUsageByTurn`.
	///
	/// Eleventh round, finding 7: individual counts are bounded (tenth round), but the
	/// COLLECTION was decoded and appended without limit — a corrupt or very long-lived
	/// session grew memory, decode time, disk, and save cost without bound, and
	/// `clampedSum` only prevented arithmetic overflow AFTER the whole array was
	/// allocated and traversed.
	public static let maxRetainedTurns = 512

	/// Domain bound for a DERIVED single-turn total carried on a summary row (thirteenth
	/// round, finding 3). A single turn's provider total is `prompt + completion` (two
	/// fields each ≤ `maxPersistedTokenCount`), and a Gemini turn-total can fall back to
	/// `estimatedInputTokens` (three fields), so a legitimate single-turn derived reading
	/// can reach 3e12 — the twelfth round pushed it through the single-field 1e12 bound
	/// and silently dropped it to nil. Three ≤3e12 addends still cannot overflow `Int`.
	public static let maxDerivedTotalCount = 3 * maxPersistedTokenCount

	/// A derived single-turn total within the wider derived domain, or nil.
	public static func boundedDerivedTotalCount(_ raw: Int) -> Int? {
		guard raw > 0 else { return nil }
		return raw <= maxDerivedTotalCount ? raw : nil
	}

	/// One row's OpenCode latest reading, using OpenCode's per-row rule (context-first,
	/// provider-total-second). For a summary row this is the reading preserved from the
	/// dropped block, NEVER the block aggregate (thirteenth round, finding 3 — the twelfth
	/// round stored only a provider-total, so a dropped block ending in a context-bearing
	/// turn restored the wrong number).
	public var openCodeLatestReading: Int? {
		if isCumulativeSummary { return summarizedOpenCodeLatestReading }
		if let context = contextUsedTokens, context > 0 { return context }
		return providerTotalTokens > 0 ? providerTotalTokens : nil
	}

	/// One row's Gemini turn total, using Gemini's per-row rule (provider-total-first,
	/// estimated-input-second). For a summary row this is the LAST real dropped turn's
	/// total, used only as the `lastTotalTokens` fallback — never the cumulative aggregate.
	public var geminiLatestTurnTotal: Int? {
		if isCumulativeSummary { return summarizedGeminiLastTurnTotal }
		if providerTotalTokens > 0 { return providerTotalTokens }
		return estimatedInputTokens > 0 ? estimatedInputTokens : nil
	}

	/// A row's contribution to Gemini's CUMULATIVE total. A summary contributes the whole
	/// dropped block's cumulative sum (preserving estimated-input-only dropped turns that
	/// the twelfth round's prompt/completion-only aggregate silently lost); a real row
	/// contributes its own turn total.
	public var geminiCumulativeContribution: Int? {
		if isCumulativeSummary { return summarizedGeminiCumulativeTotal }
		return geminiLatestTurnTotal
	}

	/// True when this detailed row carries any summary-only companion field — an invariant
	/// violation used by `validatedCollection` to fail closed (thirteenth round, finding 5).
	public var hasSummaryCompanionFields: Bool {
		summarizedOpenCodeLatestReading != nil
			|| summarizedGeminiLastTurnTotal != nil
			|| summarizedGeminiCumulativeTotal != nil
	}

	/// True when this row's summary metadata was PRESENT but invalid (fourteenth round,
	/// finding 1). The thirteenth round bounded summary fields at the boundary but the
	/// bounding ERASED the evidence: a `summarizedTurnCount` of 0, -1, or beyond the domain
	/// became `nil`, so the aggregate row stopped looking like a summary and its aggregate
	/// prompt/completion counts were reinterpreted as one real detailed turn. A present
	/// marker — valid or not — claims the row is an aggregate; when the claim is corrupt
	/// the row must be DISCARDED, never promoted to a turn. Distinct from `nil` marker
	/// (absent key = legacy real turn).
	public var hasInvalidSummaryMetadata: Bool {
		hasInvalidSummaryMarker || hasInvalidSummaryCompanion
	}

	/// A copy of this row with every summary marker/companion field removed — the fail-closed
	/// normalization for an orphan-companion detailed row (its base counts are a real turn).
	public func strippingSummaryMetadata() -> AgentTokenUsagePersist {
		AgentTokenUsagePersist(
			promptTokens: promptTokens,
			completionTokens: completionTokens,
			contextUsedTokens: contextUsedTokens,
			estimatedUserInputTokens: estimatedUserInputTokens,
			estimatedToolInputTokens: estimatedToolInputTokens,
			estimatedToolOutputTokens: estimatedToolOutputTokens,
			timestamp: timestamp
		)
	}

	/// TYPED, PROVIDER-CORRECT summary accumulation for bounded retention (twelfth round
	/// finding 2; corrected thirteenth round finding 3). The summary preserves each
	/// provider's own latest-reading rule over the dropped block — OpenCode's
	/// context-first reading, Gemini's last real-turn total AND its cumulative sum — so a
	/// latest-reading consumer never reads an aggregate as a single turn and a cumulative
	/// consumer never loses estimated-input-only dropped turns.
	private struct SummaryAccumulator {
		var droppedTurnCount = 0
		var promptSum = 0
		var completionSum = 0
		var estimatedUserSum = 0
		var estimatedToolInputSum = 0
		var estimatedToolOutputSum = 0
		var lastContextUsedTokens: Int?      // Claude latest reading (context only)
		var latestOpenCodeReading: Int?      // OpenCode reversed-scan reading
		var latestGeminiTurnTotal: Int?      // Gemini last real-turn total
		var geminiCumulativeTotal = 0        // Gemini cumulative aggregate of the block
		var lastTimestamp: Date?

		mutating func fold(_ row: AgentTokenUsagePersist) {
			// A folded row may itself be a summary from an earlier retention pass; its
			// aggregates merge and its dropped count accumulates (clamped, never trapping).
			droppedTurnCount = AgentTokenUsagePersist.clampedSum([droppedTurnCount, row.summarizedTurnCount ?? 1])
			promptSum = AgentTokenUsagePersist.clampedSum([promptSum, row.promptTokens])
			completionSum = AgentTokenUsagePersist.clampedSum([completionSum, row.completionTokens])
			estimatedUserSum = AgentTokenUsagePersist.clampedSum([estimatedUserSum, row.estimatedUserInputTokens])
			estimatedToolInputSum = AgentTokenUsagePersist.clampedSum([estimatedToolInputSum, row.estimatedToolInputTokens])
			estimatedToolOutputSum = AgentTokenUsagePersist.clampedSum([estimatedToolOutputSum, row.estimatedToolOutputTokens])
			if let context = row.contextUsedTokens {
				lastContextUsedTokens = context
			}
			// Provider-specific latest readings advance ONLY when the folded row offers one,
			// so the reversed-scan semantics are preserved through the collapse.
			if let ocReading = row.openCodeLatestReading {
				latestOpenCodeReading = ocReading
			}
			if let gTurn = row.geminiLatestTurnTotal {
				latestGeminiTurnTotal = gTurn
			}
			if let gCumulative = row.geminiCumulativeContribution {
				geminiCumulativeTotal = AgentTokenUsagePersist.clampedSum([geminiCumulativeTotal, gCumulative])
			}
			lastTimestamp = row.timestamp
		}

		func summaryRow() -> AgentTokenUsagePersist {
			AgentTokenUsagePersist(
				promptTokens: promptSum,
				completionTokens: completionSum,
				// The last dropped context reading IS legitimate latest-reading evidence
				// (Claude reads this field, and only this field, from a summary).
				contextUsedTokens: lastContextUsedTokens,
				estimatedUserInputTokens: estimatedUserSum,
				estimatedToolInputTokens: estimatedToolInputSum,
				estimatedToolOutputTokens: estimatedToolOutputSum,
				timestamp: lastTimestamp ?? Date(timeIntervalSince1970: 0),
				summarizedTurnCount: droppedTurnCount,
				summarizedOpenCodeLatestReading: latestOpenCodeReading,
				summarizedGeminiLastTurnTotal: latestGeminiTurnTotal,
				summarizedGeminiCumulativeTotal: geminiCumulativeTotal > 0 ? geminiCumulativeTotal : nil
			)
		}
	}

	/// Provider-correct bounded retention (twelfth round finding 2; corrected thirteenth
	/// round finding 3). When the row count exceeds the bound, everything older than the
	/// detailed suffix is collapsed into ONE TYPED summary row that preserves each
	/// provider's latest-reading and cumulative semantics. A row count already within the
	/// bound is validated for summary invariants and returned.
	public static func retained(_ rows: [AgentTokenUsagePersist], limit: Int = maxRetainedTurns) -> [AgentTokenUsagePersist] {
		let limit = max(1, limit)
		let rows = validatedCollection(rows)
		guard rows.count > limit else { return rows }
		// One slot is reserved for the summary row, so the detailed suffix is limit-1.
		let detailCount = max(1, limit - 1)
		var accumulator = SummaryAccumulator()
		for row in rows[0..<(rows.count - detailCount)] {
			accumulator.fold(row)
		}
		return [accumulator.summaryRow()] + Array(rows[(rows.count - detailCount)...])
	}

	/// FAIL-CLOSED validation of a decoded usage collection's summary structure
	/// (thirteenth round, finding 5). A canonical collection has at most one summary, only
	/// at index zero, and no detailed row carrying summary-only companion fields. A file an
	/// agent process can influence may violate any of these — a summary in the middle, two
	/// summaries, or a real turn wearing companion fields. When it does, the summary
	/// metadata is DISTRUSTED: every misplaced summary row is DISCARDED entirely (its
	/// aggregate is never reinterpreted as one detailed turn), orphan companion fields are
	/// stripped from real turns, and the surviving detailed turns are re-bounded. A
	/// legitimate collection (including a legacy one with no summary fields) is returned
	/// unchanged.
	public static func validatedCollection(_ rows: [AgentTokenUsagePersist]) -> [AgentTokenUsagePersist] {
		let summaryIndices = rows.indices.filter { rows[$0].isCumulativeSummary }
		let misplacedSummary = summaryIndices.contains { $0 != 0 }
		let multipleSummaries = summaryIndices.count > 1
		let orphanCompanions = rows.indices.contains { !rows[$0].isCumulativeSummary && rows[$0].hasSummaryCompanionFields }
		// Fourteenth round, finding 1: PRESENT-but-invalid summary metadata is a
		// structural violation too — previously it was normalized to nil before this
		// validation ever ran, so a corrupt aggregate looked like a clean real turn.
		let invalidMetadata = rows.contains(where: \.hasInvalidSummaryMetadata)
		guard misplacedSummary || multipleSummaries || orphanCompanions || invalidMetadata else {
			return rows
		}
		// Fail closed: drop every summary row AND every row whose summariness claim is
		// corrupt (an invalid marker still claims the row is an aggregate — its base
		// counts are a block sum, never one turn), strip orphan companion noise from real
		// turns, and re-bound. The malformed aggregates are lost, never fabricated into
		// turns.
		let detailedOnly = rows.compactMap { row -> AgentTokenUsagePersist? in
			if row.isCumulativeSummary || row.hasInvalidSummaryMarker { return nil }
			if row.hasSummaryCompanionFields || row.hasInvalidSummaryCompanion {
				return row.strippingSummaryMetadata()
			}
			return row
		}
		return retained(detailedOnly)
	}

	/// Streaming, bounded, INVARIANT-ENFORCING decode of a persisted usage collection
	/// (twelfth round finding 3; hardened thirteenth round findings 3 & 5). Rows are
	/// decoded one at a time so the typed-row buffer never exceeds ~2× the retention limit
	/// regardless of file size. A legitimate leading summary (stream index 0 only) seeds
	/// the accumulator; any later or duplicate summary is DROPPED (its aggregate never
	/// becomes a turn), an orphan-companion detailed row is stripped to a real turn, and
	/// the `malformedSummaryStructure` flag records that distrust occurred.
	///
	/// `probe` (injected via `JSONDecoder.userInfo`) records the decode ORDER evidence so a
	/// regression can prove the bound holds DURING decode, not after a decode-then-prune.
	public static func decodeBoundedRetained<K: CodingKey>(
		from container: KeyedDecodingContainer<K>,
		forKey key: K,
		probe: AgentUsageDecodeProbe? = nil,
		limit: Int = maxRetainedTurns
	) throws -> [AgentTokenUsagePersist] {
		guard container.contains(key) else { return [] }
		if try container.decodeNil(forKey: key) { return [] }
		var unkeyed = try container.nestedUnkeyedContainer(forKey: key)
		let limit = max(1, limit)
		let detailCount = max(1, limit - 1)
		var accumulator = SummaryAccumulator()
		var buffer: [AgentTokenUsagePersist] = []
		var foldedPrefixCount = 0
		var streamIndex = 0
		var sawLeadingSummary = false
		var malformedStructure = false
		while !unkeyed.isAtEnd {
			var row = try unkeyed.decode(AgentTokenUsagePersist.self)
			probe?.observeRow()
			if row.hasInvalidSummaryMarker || (row.isCumulativeSummary && row.hasInvalidSummaryCompanion) {
				// PRESENT-but-invalid summary metadata (fourteenth round, finding 1): the
				// row claims to be an aggregate but the claim is corrupt. It is DROPPED —
				// its aggregate base counts must never be reinterpreted as one real
				// detailed turn — and the whole summary structure is distrusted.
				malformedStructure = true
				streamIndex += 1
				continue
			}
			if row.isCumulativeSummary {
				if streamIndex == 0, !sawLeadingSummary {
					// The one legitimate place for a summary: seed the accumulator with it.
					sawLeadingSummary = true
					accumulator.fold(row)
					streamIndex += 1
					probe?.observeBuffer(count: buffer.count)
					continue
				}
				// A misplaced/duplicate summary is DROPPED — never folded, never a turn —
				// and its presence means the WHOLE structure is untrusted (thirteenth
				// round, finding 5): a file carrying two summaries gives no reason to trust
				// that the first is legitimate either.
				malformedStructure = true
				streamIndex += 1
				continue
			}
			if row.hasSummaryCompanionFields || row.hasInvalidSummaryCompanion {
				// Orphan companion fields on a real turn — valid OR out-of-domain: keep
				// the turn (its base counts are real-turn evidence), drop the noise, and
				// distrust the collection's summary structure.
				malformedStructure = true
				row = row.strippingSummaryMetadata()
			}
			buffer.append(row)
			if accumulator.droppedTurnCount > 0 || buffer.count - foldedPrefixCount > limit {
				while buffer.count - foldedPrefixCount > detailCount {
					accumulator.fold(buffer[foldedPrefixCount])
					foldedPrefixCount += 1
				}
				if foldedPrefixCount >= limit {
					buffer.removeFirst(foldedPrefixCount)
					foldedPrefixCount = 0
				}
			}
			probe?.observeBuffer(count: buffer.count)
			streamIndex += 1
		}
		if malformedStructure { probe?.markMalformedSummaryStructure() }
		let detail = foldedPrefixCount > 0 ? Array(buffer[foldedPrefixCount...]) : buffer
		let result = accumulator.droppedTurnCount > 0 ? [accumulator.summaryRow()] + detail : detail
		guard malformedStructure else { return result }
		// FAIL CLOSED: any malformed summary metadata distrusts EVERY summary — including a
		// possibly-legitimate leading one that was already folded. Keep only the real
		// detailed turns (their base counts are trustworthy), strip any companion noise,
		// and re-bound. A malformed aggregate is discarded, never fabricated into a turn.
		let detailedOnly = result.compactMap { row -> AgentTokenUsagePersist? in
			if row.isCumulativeSummary { return nil }
			return row.hasSummaryCompanionFields ? row.strippingSummaryMetadata() : row
		}
		return retained(detailedOnly)
	}

	public let promptTokens: Int
	public let completionTokens: Int
	public let contextUsedTokens: Int?
	public let estimatedUserInputTokens: Int
	public let estimatedToolInputTokens: Int
	public let estimatedToolOutputTokens: Int
	public let timestamp: Date
	/// Non-nil (and positive) marks this row as the cumulative summary of that many
	/// dropped older turns rather than one real turn (twelfth round, finding 2).
	public let summarizedTurnCount: Int?
	/// OpenCode's latest reading over the dropped block (context-first, provider-total-
	/// second) — the only OpenCode evidence a summary offers a reversed scan (thirteenth
	/// round, finding 3). In the DERIVED domain (up to 3e12).
	public let summarizedOpenCodeLatestReading: Int?
	/// Gemini's LAST real-turn total over the dropped block — the `lastTotalTokens`
	/// fallback, never the aggregate. In the DERIVED domain (thirteenth round, finding 3).
	public let summarizedGeminiLastTurnTotal: Int?
	/// Gemini's CUMULATIVE total over the dropped block — sums each dropped turn's
	/// Gemini turn total, preserving estimated-input-only turns the twelfth round lost.
	public let summarizedGeminiCumulativeTotal: Int?
	/// Decode/construction-time evidence that `summarizedTurnCount` was PRESENT but out of
	/// its domain (fourteenth round, finding 1). Never persisted; `encode(to:)` omits it.
	public let hasInvalidSummaryMarker: Bool
	/// Decode/construction-time evidence that at least one summary companion field was
	/// PRESENT but out of the derived domain (fourteenth round, finding 1). Never persisted.
	public let hasInvalidSummaryCompanion: Bool

	/// True when this row aggregates dropped turns instead of describing one real turn.
	public var isCumulativeSummary: Bool {
		(summarizedTurnCount ?? 0) > 0
	}

	public init(
		promptTokens: Int,
		completionTokens: Int,
		contextUsedTokens: Int? = nil,
		estimatedUserInputTokens: Int = 0,
		estimatedToolInputTokens: Int = 0,
		estimatedToolOutputTokens: Int = 0,
		timestamp: Date = Date(),
		summarizedTurnCount: Int? = nil,
		summarizedOpenCodeLatestReading: Int? = nil,
		summarizedGeminiLastTurnTotal: Int? = nil,
		summarizedGeminiCumulativeTotal: Int? = nil
	) {
		self.promptTokens = Self.boundedTokenCount(promptTokens)
		self.completionTokens = Self.boundedTokenCount(completionTokens)
		if let contextUsedTokens {
			let normalized = Self.boundedTokenCount(contextUsedTokens)
			self.contextUsedTokens = normalized > 0 ? normalized : nil
		} else {
			self.contextUsedTokens = nil
		}
		self.estimatedUserInputTokens = Self.boundedTokenCount(estimatedUserInputTokens)
		self.estimatedToolInputTokens = Self.boundedTokenCount(estimatedToolInputTokens)
		self.estimatedToolOutputTokens = Self.boundedTokenCount(estimatedToolOutputTokens)
		self.timestamp = timestamp
		// PRESENT-but-invalid summary metadata is remembered, not erased (fourteenth
		// round, finding 1): a marker of 0/-1/out-of-domain is normalized to nil for the
		// stored field, but the row keeps the evidence so the collection validators can
		// discard the aggregate instead of reinterpreting its base counts as a real turn.
		if let summarizedTurnCount {
			let normalized = Self.boundedTokenCount(summarizedTurnCount)
			self.summarizedTurnCount = normalized > 0 ? normalized : nil
			self.hasInvalidSummaryMarker = normalized <= 0
		} else {
			self.summarizedTurnCount = nil
			self.hasInvalidSummaryMarker = false
		}
		// Derived single-turn readings use the WIDER derived domain (thirteenth round,
		// finding 3) so a legitimate 2e12 provider total is not clipped to nil by the
		// single-field 1e12 bound.
		var companionInvalid = false
		func boundedCompanion(_ raw: Int?) -> Int? {
			guard let raw else { return nil }
			guard let bounded = Self.boundedDerivedTotalCount(raw) else {
				companionInvalid = true
				return nil
			}
			return bounded
		}
		self.summarizedOpenCodeLatestReading = boundedCompanion(summarizedOpenCodeLatestReading)
		self.summarizedGeminiLastTurnTotal = boundedCompanion(summarizedGeminiLastTurnTotal)
		self.summarizedGeminiCumulativeTotal = boundedCompanion(summarizedGeminiCumulativeTotal)
		self.hasInvalidSummaryCompanion = companionInvalid
	}

	public var estimatedInputTokens: Int {
		estimatedUserInputTokens + estimatedToolInputTokens + estimatedToolOutputTokens
	}

	public var providerTotalTokens: Int {
		promptTokens + completionTokens
	}

	public var totalTokens: Int {
		if let contextUsedTokens, contextUsedTokens > 0 {
			return contextUsedTokens
		}
		let provider = providerTotalTokens
		if provider > 0 {
			return provider
		}
		return estimatedInputTokens
	}

	enum CodingKeys: String, CodingKey {
		case promptTokens
		case completionTokens
		case contextUsedTokens
		case estimatedUserInputTokens
		case estimatedToolInputTokens
		case estimatedToolOutputTokens
		case timestamp
		case summarizedTurnCount
		case summarizedOpenCodeLatestReading
		case summarizedGeminiLastTurnTotal
		case summarizedGeminiCumulativeTotal
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		// Persisted counts are provider-influenced and must be bounded here, before any
		// consumer adds them together (tenth round, finding 7).
		promptTokens = Self.boundedTokenCount(try container.decode(Int.self, forKey: .promptTokens))
		completionTokens = Self.boundedTokenCount(try container.decode(Int.self, forKey: .completionTokens))
		if let decodedContext = try container.decodeIfPresent(Int.self, forKey: .contextUsedTokens) {
			let normalized = Self.boundedTokenCount(decodedContext)
			contextUsedTokens = normalized > 0 ? normalized : nil
		} else {
			contextUsedTokens = nil
		}
		estimatedUserInputTokens = Self.boundedTokenCount(try container.decodeIfPresent(Int.self, forKey: .estimatedUserInputTokens) ?? 0)
		estimatedToolInputTokens = Self.boundedTokenCount(try container.decodeIfPresent(Int.self, forKey: .estimatedToolInputTokens) ?? 0)
		estimatedToolOutputTokens = Self.boundedTokenCount(try container.decodeIfPresent(Int.self, forKey: .estimatedToolOutputTokens) ?? 0)
		timestamp = try container.decode(Date.self, forKey: .timestamp)
		// Absent in every pre-twelfth-round file (legacy rows are real turns), and
		// bounded like every other persisted count. The summary structure itself is
		// validated fail-closed at the collection boundary (thirteenth round, finding 5).
		//
		// Fourteenth round, finding 1: bounding must not ERASE the summariness claim. The
		// decode distinguishes three states — key ABSENT (legacy real turn), key present
		// and VALID (summary), and key PRESENT BUT INVALID (a corrupt aggregate that must
		// never be reinterpreted as a real turn). The invalid state is preserved on the
		// row so `validatedCollection`/`decodeBoundedRetained` can discard it fail-closed.
		if let decodedSummaryCount = try container.decodeIfPresent(Int.self, forKey: .summarizedTurnCount) {
			let normalized = Self.boundedTokenCount(decodedSummaryCount)
			summarizedTurnCount = normalized > 0 ? normalized : nil
			hasInvalidSummaryMarker = normalized <= 0
		} else {
			summarizedTurnCount = nil
			hasInvalidSummaryMarker = false
		}
		var companionInvalid = false
		func decodeCompanion(_ key: CodingKeys) throws -> Int? {
			guard let raw = try container.decodeIfPresent(Int.self, forKey: key) else { return nil }
			guard let bounded = Self.boundedDerivedTotalCount(raw) else {
				companionInvalid = true
				return nil
			}
			return bounded
		}
		summarizedOpenCodeLatestReading = try decodeCompanion(.summarizedOpenCodeLatestReading)
		summarizedGeminiLastTurnTotal = try decodeCompanion(.summarizedGeminiLastTurnTotal)
		summarizedGeminiCumulativeTotal = try decodeCompanion(.summarizedGeminiCumulativeTotal)
		hasInvalidSummaryCompanion = companionInvalid
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(promptTokens, forKey: .promptTokens)
		try container.encode(completionTokens, forKey: .completionTokens)
		try container.encodeIfPresent(contextUsedTokens, forKey: .contextUsedTokens)
		try container.encode(estimatedUserInputTokens, forKey: .estimatedUserInputTokens)
		try container.encode(estimatedToolInputTokens, forKey: .estimatedToolInputTokens)
		try container.encode(estimatedToolOutputTokens, forKey: .estimatedToolOutputTokens)
		try container.encode(timestamp, forKey: .timestamp)
		try container.encodeIfPresent(summarizedTurnCount, forKey: .summarizedTurnCount)
		try container.encodeIfPresent(summarizedOpenCodeLatestReading, forKey: .summarizedOpenCodeLatestReading)
		try container.encodeIfPresent(summarizedGeminiLastTurnTotal, forKey: .summarizedGeminiLastTurnTotal)
		try container.encodeIfPresent(summarizedGeminiCumulativeTotal, forKey: .summarizedGeminiCumulativeTotal)
	}
}

