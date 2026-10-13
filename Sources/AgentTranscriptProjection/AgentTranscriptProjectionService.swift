import AgentTranscriptAssembly
import Foundation
import AgentRuntimeKit
import AgentTranscriptPersistence

fileprivate struct ClusterSummaryCacheKey: Hashable {
	let rowIDs: [UUID]
}

fileprivate final class AgentTranscriptProjectionBuildContext {
    let toolProcessor: (AgentChatItem) -> AgentTranscriptToolExecution?
    var clusterSummaryByRowIDs: [ClusterSummaryCacheKey: AgentTranscriptClusterSummary] = [:]
    init(services: AgentTranscriptProjectionServices) { toolProcessor = services.makeToolProcessor() }
}

fileprivate struct CollapsibleLeafDescriptor {
	let kind: AgentTranscriptRenderBlockKind
	let rowCount: Int
	let containsProgressNote: Bool

	init(
		kind: AgentTranscriptRenderBlockKind,
		rowCount: Int,
		containsProgressNote: Bool = false
	) {
		self.kind = kind
		self.rowCount = rowCount
		self.containsProgressNote = containsProgressNote
	}
}

public struct AgentTranscriptProjectionService {
    private let services: AgentTranscriptProjectionServices
    public init(services: AgentTranscriptProjectionServices) { self.services = services }

	private func debugRowSummary(_ item: AgentChatItem) -> String {
		let label = item.toolName ?? item.kind.rawValue
		return "\(item.sequenceIndex):\(item.kind.rawValue):\(label):stream=\(item.isStreaming)"
	}

	private func debugBlockSummary(_ block: AgentTranscriptRenderBlock) -> String {
		let rowSummary = block.rows.map { "\($0.sequenceIndex):\($0.kind.rawValue)" }.joined(separator: ",")
		return "\(block.kind.rawValue){\(rowSummary)}"
	}

	private struct ReusableProjectionPrefix {
		let turnCount: Int
		let workingBlocks: [AgentTranscriptRenderBlock]
		let archivedBlocks: [AgentTranscriptRenderBlock]
		let workingRows: [AgentChatItem]
		let archivedRows: [AgentChatItem]
		let rowAnchorIndex: [UUID: AgentTranscriptAnchor]
		let anchorBlockIndex: [AgentTranscriptAnchor: String]
	}

	private struct GroupedHistoryCollapsePlan {
		let contentBlocks: [AgentTranscriptRenderBlock]
		let conclusionBlocks: [AgentTranscriptRenderBlock]
		let collapsedPrefix: [AgentTranscriptRenderBlock]
		let groupedPrefix: [AgentTranscriptRenderBlock]
		let detailedSuffix: [AgentTranscriptRenderBlock]
		let bufferedLeadingAssistant: AgentTranscriptRenderBlock?
		let collapseDigest: String
	}

	/// Refreshes completed full-turn grouped-history summary caches.
	/// Also intentionally tightens `frozenDetailedToolTailLimit` when an eligible completed
	/// full turn emits grouped history under the current newest-first allocation. Callers
	/// must use the returned transcript; this method is not cache-only.
	public func refreshCompletedFullTurnGroupedHistoryCaches(in transcript: AgentTranscript) -> AgentTranscript {
		var updatedTranscript = transcript
		let context = AgentTranscriptProjectionBuildContext(services: services)
		let detailedToolTailLimits = detailedToolTailLimits(for: updatedTranscript)
		for turnIndex in updatedTranscript.turns.indices {
			let turn = updatedTranscript.turns[turnIndex]
			let isEligible = turn.retentionTier == .full
				&& turn.isCompleted
				&& !turn.responseSpans.contains(where: { $0.lifecycle == .open })
			guard isEligible else {
				for spanIndex in updatedTranscript.turns[turnIndex].responseSpans.indices {
					updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = nil
				}
				continue
			}
			let detailedToolTailLimit = detailedToolTailLimits[turn.id] ?? 0
			var didCollapseTurn = false
			var emittedConclusionActivityIDs = Set<UUID>()
			for spanIndex in updatedTranscript.turns[turnIndex].responseSpans.indices {
				let span = updatedTranscript.turns[turnIndex].responseSpans[spanIndex]
				let leafBlocks = fullSpanLeafBlocks(
					for: span,
					in: turn,
					archived: false,
					emittedConclusionActivityIDs: &emittedConclusionActivityIDs
				)
				guard let plan = groupedHistoryCollapsePlan(
					in: leafBlocks,
					spanID: span.id,
					detailedToolTailLimit: detailedToolTailLimit
				) else {
					updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = nil
					continue
				}
				didCollapseTurn = true
				if let cache = span.fullRenderGroupedHistoryCache,
					cache.detailedToolTailLimit == detailedToolTailLimit,
					cache.collapseDigest == plan.collapseDigest {
					continue
				}
				let summary = groupedHistorySummary(
					for: plan.groupedPrefix,
					summarySourceBlocks: plan.collapsedPrefix,
					context: context
				)
				updatedTranscript.turns[turnIndex].responseSpans[spanIndex].fullRenderGroupedHistoryCache = .init(
					detailedToolTailLimit: detailedToolTailLimit,
					collapseDigest: plan.collapseDigest,
					summary: summary
				)
			}
			if didCollapseTurn {
				let frozenLimit = normalizedFrozenDetailedToolTailLimit(for: updatedTranscript.turns[turnIndex])
				if frozenLimit == nil || detailedToolTailLimit < (frozenLimit ?? Int.max) {
					updatedTranscript.turns[turnIndex].frozenDetailedToolTailLimit = detailedToolTailLimit
				}
			}
		}
		return updatedTranscript
	}

	public func build(
		from transcript: AgentTranscript,
		protection: AgentTranscriptProjectionProtection = .none
	) -> AgentTranscriptProjection {
		buildWithCaches(
			from: transcript,
			protection: protection,
			turnCaches: [:]
		).projection
	}

	public func buildWithCaches(
		from transcript: AgentTranscript,
		protection: AgentTranscriptProjectionProtection = .none,
		turnCaches: [UUID: AgentTranscriptTurnProjectionCache]
	) -> AgentTranscriptProjectionBuildResult {
		buildProjection(
			from: transcript,
			protection: protection,
			reusablePrefix: nil,
			turnCaches: turnCaches
		)
	}

	public func buildReusingFrozenPrefix(
		from transcript: AgentTranscript,
		previousTranscript: AgentTranscript,
		previousProjection: AgentTranscriptProjection,
		previousProtection: AgentTranscriptProjectionProtection,
		protection: AgentTranscriptProjectionProtection = .none,
		reusableFrozenPrefixTurnCount: Int
	) -> AgentTranscriptProjection? {
		guard reusableFrozenPrefixTurnCount > 0,
			protection == previousProtection,
			AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(in: transcript) == reusableFrozenPrefixTurnCount,
			previousTranscript.turns.count >= reusableFrozenPrefixTurnCount,
			transcript.turns.count > reusableFrozenPrefixTurnCount,
			previousTranscript.turns.prefix(reusableFrozenPrefixTurnCount).elementsEqual(
				transcript.turns.prefix(reusableFrozenPrefixTurnCount)
			)
		else {
			return nil
		}
		let prefixTurnIDs = Set(transcript.turns.prefix(reusableFrozenPrefixTurnCount).map(\.id))
		let reusablePrefix = reusableProjectionPrefix(
			from: previousProjection,
			turnIDs: prefixTurnIDs,
			turnCount: reusableFrozenPrefixTurnCount
		)
		return buildProjection(
			from: transcript,
			protection: protection,
			reusablePrefix: reusablePrefix,
			turnCaches: [:]
		).projection
	}

	private func buildProjection(
		from transcript: AgentTranscript,
		protection: AgentTranscriptProjectionProtection,
		reusablePrefix: ReusableProjectionPrefix?,
		turnCaches: [UUID: AgentTranscriptTurnProjectionCache]
	) -> AgentTranscriptProjectionBuildResult {
		#if DEBUG
		let startedAt = services.clock()
		#endif
		let context = AgentTranscriptProjectionBuildContext(services: services)
		let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
		var workingBlocks: [AgentTranscriptRenderBlock] = reusablePrefix?.workingBlocks ?? []
		var archivedBlocks: [AgentTranscriptRenderBlock] = reusablePrefix?.archivedBlocks ?? []
		var workingRows: [AgentChatItem] = reusablePrefix?.workingRows ?? []
		var archivedRows: [AgentChatItem] = reusablePrefix?.archivedRows ?? []
		var rowAnchorIndex: [UUID: AgentTranscriptAnchor] = reusablePrefix?.rowAnchorIndex ?? [:]
		var anchorBlockIndex: [AgentTranscriptAnchor: String] = reusablePrefix?.anchorBlockIndex ?? [:]
		let transcriptTurnIDs = Set(transcript.turns.map(\.id))
		let protectedTurnID = protection.protectedTurnID
		var updatedTurnCaches = turnCaches.filter { transcriptTurnIDs.contains($0.key) }
		var cacheHitCount = 0

		for turn in transcript.turns.dropFirst(reusablePrefix?.turnCount ?? 0) {
			if let cachedProjection = cachedProjection(
				for: turn,
				protectedTurnID: protectedTurnID,
				turnCaches: updatedTurnCaches
			) {
				appendCachedProjectionState(
					cachedProjection,
					workingBlocks: &workingBlocks,
					archivedBlocks: &archivedBlocks,
					workingRows: &workingRows,
					archivedRows: &archivedRows,
					rowAnchorIndex: &rowAnchorIndex,
					anchorBlockIndex: &anchorBlockIndex
				)
				cacheHitCount += 1
				continue
			}

			let workingBlockStart = workingBlocks.count
			let archivedBlockStart = archivedBlocks.count
			appendProjectionState(
				for: turn,
				detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0,
				context: context,
				workingBlocks: &workingBlocks,
				archivedBlocks: &archivedBlocks,
				workingRows: &workingRows,
				archivedRows: &archivedRows,
				rowAnchorIndex: &rowAnchorIndex,
				anchorBlockIndex: &anchorBlockIndex
			)
			if turn.isCompleted, turn.id != protectedTurnID {
				let newWorkingBlocks = Array(workingBlocks.dropFirst(workingBlockStart))
				let newArchivedBlocks = Array(archivedBlocks.dropFirst(archivedBlockStart))
				updatedTurnCaches[turn.id] = projectionCache(
					for: turn,
					token: validationToken(for: turn),
					workingBlocks: newWorkingBlocks,
					archivedBlocks: newArchivedBlocks,
					workingRows: projectionRows(for: newWorkingBlocks),
					archivedRows: projectionRows(for: newArchivedBlocks),
					rowAnchorIndex: rowAnchorIndex,
					anchorBlockIndex: anchorBlockIndex
				)
			} else if !turn.isCompleted {
				updatedTurnCaches.removeValue(forKey: turn.id)
			}
		}

		workingRows.sort { lhs, rhs in lhs.sequenceIndex < rhs.sequenceIndex }
		archivedRows.sort { lhs, rhs in lhs.sequenceIndex < rhs.sequenceIndex }
		let projection = AgentTranscriptProjection(
			workingBlocks: workingBlocks,
			archivedBlocks: archivedBlocks,
			workingRows: workingRows,
			archivedRows: archivedRows,
			rowAnchorIndex: rowAnchorIndex,
			anchorBlockIndex: anchorBlockIndex,
			workingUnitCount: workingBlocks.count
		)
		#if DEBUG
		let workingRowTail = Array(workingRows.suffix(8)).map(debugRowSummary).joined(separator: ", ")
		let workingBlockTail = Array(workingBlocks.suffix(8)).map(debugBlockSummary).joined(separator: " | ")
		services.log(
			"[AgentTranscriptProjection] build turns=\(transcript.turns.count) workingRows=\(workingRows.count) workingBlocks=\(workingBlocks.count) reusedPrefixTurns=\(reusablePrefix?.turnCount ?? 0) cacheHits=\(cacheHitCount) workingRowTail=[\(workingRowTail)] workingBlockTail=[\(workingBlockTail)]"
		)
		if services.diagnosticsEnabled() {
			services.observeBuild(.init(
				turnCount: transcript.turns.count,
				reusedPrefixTurnCount: reusablePrefix?.turnCount ?? 0,
				cacheHitCount: cacheHitCount,
				workingBlockCount: workingBlocks.count,
				archivedBlockCount: archivedBlocks.count,
				workingRowCount: workingRows.count,
				archivedRowCount: archivedRows.count,
				workingUnitCount: projection.workingUnitCount,
				durationMS: max(0, (services.clock() - startedAt) * 1000)
			))
		}
		#endif
		return AgentTranscriptProjectionBuildResult(
			projection: projection,
			updatedTurnCaches: updatedTurnCaches
		)
	}

	public func updatedTurnCaches(
		for transcript: AgentTranscript,
		projection: AgentTranscriptProjection,
		protection: AgentTranscriptProjectionProtection = .none,
		existingTurnCaches: [UUID: AgentTranscriptTurnProjectionCache] = [:]
	) -> [UUID: AgentTranscriptTurnProjectionCache] {
		let transcriptTurnIDs = Set(transcript.turns.map(\.id))
		let protectedTurnID = protection.protectedTurnID
		var updatedTurnCaches = existingTurnCaches.filter { transcriptTurnIDs.contains($0.key) }
		for turn in transcript.turns {
			guard turn.isCompleted else {
				updatedTurnCaches.removeValue(forKey: turn.id)
				continue
			}
			guard turn.id != protectedTurnID else { continue }
			updatedTurnCaches[turn.id] = projectionCache(
				for: turn,
				token: validationToken(for: turn),
				projection: projection
			)
		}
		return updatedTurnCaches
	}

	public func rows(for turn: AgentTranscriptTurn, archived: Bool, isLatestTurn: Bool = true) -> [AgentChatItem] {
		if turn.retentionTier != .full {
			return compactedRows(for: turn)
		}
		let context = AgentTranscriptProjectionBuildContext(services: services)
		return blocks(
			for: turn,
			archived: archived,
			isLatestTurn: isLatestTurn,
			context: context
		).flatMap(projectionRows(for:))
	}

	public func estimatedWorkingUnitCount(for transcript: AgentTranscript) -> Int {
		let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
		return transcript.turns.reduce(into: 0) { partial, turn in
			guard turn.retentionTier != .archived else { return }
			partial += estimatedBlockCount(
				for: turn,
				detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0
			)
		}
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public func estimatedSummaryWorkingUnitContribution(for turn: AgentTranscriptTurn) -> Int {
		guard turn.retentionTier == .summary else { return 0 }
		// Must remain exactly equivalent to `estimatedBlockCount`'s `.summary` contribution:
		// summary archival subtracts this value locally instead of rebuilding full pressure.
		return compactTierBlockCount(for: turn)
	}

	public func projectionCounts(for transcript: AgentTranscript) -> AgentTranscriptProjectionCounts {
		let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
		var workingVisibleRowCount = 0
		var archivedVisibleRowCount = 0
		for turn in transcript.turns {
			let visibleRowCount: Int
			switch turn.retentionTier {
			case .full:
				visibleRowCount = fullTurnVisibleRowCount(
					for: turn,
					detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0
				)
			case .condensed, .summary:
				visibleRowCount = compactTierVisibleRowCount(for: turn)
			case .archived:
				visibleRowCount = compactedVisibleRowCount(for: turn)
			}
			if turn.retentionTier == .archived {
				archivedVisibleRowCount += visibleRowCount
			} else {
				workingVisibleRowCount += visibleRowCount
			}
		}
		return .init(
			canonicalVisibleRowCount: workingVisibleRowCount + archivedVisibleRowCount,
			defaultPresentedRowCount: workingVisibleRowCount
		)
	}

	public func projectionCounts(for projection: AgentTranscriptProjection) -> AgentTranscriptProjectionCounts {
		.init(
			canonicalVisibleRowCount: presentedItemCount(for: projection.workingBlocks)
				+ presentedItemCount(for: projection.archivedBlocks),
			defaultPresentedRowCount: presentedItemCount(for: projection.workingBlocks)
		)
	}

	public func workingProjection(from fullProjection: AgentTranscriptProjection) -> AgentTranscriptProjection {
		let workingRowIDs = Set(fullProjection.workingRows.map(\.id))
		let workingBlockIDs = Set(fullProjection.workingBlocks.map(\.id))
		return .init(
			workingBlocks: fullProjection.workingBlocks,
			workingRows: fullProjection.workingRows,
			rowAnchorIndex: filteredRowAnchorIndex(
				fullProjection.rowAnchorIndex,
				retaining: workingRowIDs
			),
			anchorBlockIndex: filteredAnchorBlockIndex(
				fullProjection.anchorBlockIndex,
				retaining: workingBlockIDs
			),
			workingUnitCount: fullProjection.workingUnitCount
		)
	}

	public func archivedProjection(from fullProjection: AgentTranscriptProjection) -> AgentArchivedTranscriptProjection {
		let archivedRowIDs = Set(fullProjection.archivedRows.map(\.id))
		let archivedBlockIDs = Set(fullProjection.archivedBlocks.map(\.id))
		return .init(
			blocks: fullProjection.archivedBlocks,
			rows: fullProjection.archivedRows,
			rowAnchorIndex: filteredRowAnchorIndex(
				fullProjection.rowAnchorIndex,
				retaining: archivedRowIDs
			),
			anchorBlockIndex: filteredAnchorBlockIndex(
				fullProjection.anchorBlockIndex,
				retaining: archivedBlockIDs
			),
			presentedRowCount: presentedItemCount(for: fullProjection.archivedBlocks),
			blockCount: fullProjection.archivedBlocks.count
		)
	}

	public func projectedVisibleRowCount(for transcript: AgentTranscript) -> Int {
		projectionCounts(for: transcript).canonicalVisibleRowCount
	}

	public func visibleToolResultRowIDs(in projection: AgentTranscriptProjection) -> Set<UUID> {
		var ids = Set<UUID>()
		ids.reserveCapacity(projection.workingRows.count + projection.archivedRows.count)
		for block in projection.workingBlocks {
			for row in block.rows where row.kind == .toolResult {
				ids.insert(row.id)
			}
		}
		for block in projection.archivedBlocks {
			for row in block.rows where row.kind == .toolResult {
				ids.insert(row.id)
			}
		}
		return ids
	}

	public func blocks(for transcript: AgentTranscript) -> [AgentTranscriptRenderBlock] {
		let context = AgentTranscriptProjectionBuildContext(services: services)
		let detailedToolTailLimits = detailedToolTailLimits(for: transcript)
		return transcript.turns.flatMap { turn in
			let archived = turn.retentionTier == .archived
			return blocksForTurn(
				turn,
				archived: archived,
				detailedToolTailLimit: detailedToolTailLimits[turn.id] ?? 0,
				context: context,
				protectDetachedFocus: false
			)
		}
	}

	private func projectionRows(for block: AgentTranscriptRenderBlock) -> [AgentChatItem] {
		switch block.kind {
		case .groupedHistory:
			return []
		case .request, .activityCluster, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
			return block.rows
		}
	}

	private func projectionRows(for blocks: [AgentTranscriptRenderBlock]) -> [AgentChatItem] {
		blocks.flatMap(projectionRows(for:))
	}

	private func reusableProjectionPrefix(
		from projection: AgentTranscriptProjection,
		turnIDs: Set<UUID>,
		turnCount: Int
	) -> ReusableProjectionPrefix {
		let workingBlocks = projection.workingBlocks.filter { turnIDs.contains($0.turnID) }
		let archivedBlocks = projection.archivedBlocks.filter { turnIDs.contains($0.turnID) }
		let reusableWorkingRowIDs = Set(workingBlocks.flatMap(projectionRows(for:)).map(\.id))
		let reusableArchivedRowIDs = Set(archivedBlocks.flatMap(projectionRows(for:)).map(\.id))
		let rowAnchorIndex = projection.rowAnchorIndex.filter { turnIDs.contains(turnID(for: $0.value)) }
		return ReusableProjectionPrefix(
			turnCount: turnCount,
			workingBlocks: workingBlocks,
			archivedBlocks: archivedBlocks,
			workingRows: projection.workingRows.filter { reusableWorkingRowIDs.contains($0.id) },
			archivedRows: projection.archivedRows.filter { reusableArchivedRowIDs.contains($0.id) },
			rowAnchorIndex: rowAnchorIndex,
			anchorBlockIndex: projection.anchorBlockIndex.filter { turnIDs.contains(turnID(for: $0.key)) }
		)
	}

	private func appendProjectionState(
		for turn: AgentTranscriptTurn,
		detailedToolTailLimit: Int,
		context: AgentTranscriptProjectionBuildContext,
		workingBlocks: inout [AgentTranscriptRenderBlock],
		archivedBlocks: inout [AgentTranscriptRenderBlock],
		workingRows: inout [AgentChatItem],
		archivedRows: inout [AgentChatItem],
		rowAnchorIndex: inout [UUID: AgentTranscriptAnchor],
		anchorBlockIndex: inout [AgentTranscriptAnchor: String]
	) {
		let archived = turn.retentionTier == .archived
		let blocks = blocksForTurn(
			turn,
			archived: archived,
			detailedToolTailLimit: detailedToolTailLimit,
			context: context,
			protectDetachedFocus: false
		)
		for block in blocks {
			let projectedRows = projectionRows(for: block)
			if archived {
				archivedBlocks.append(block)
				archivedRows.append(contentsOf: projectedRows)
			} else {
				workingBlocks.append(block)
				workingRows.append(contentsOf: projectedRows)
			}
		}
		registerAnchors(for: turn, blocks: blocks, into: &rowAnchorIndex)
		registerBlockAnchors(for: turn, blocks: blocks, into: &anchorBlockIndex)
	}

	public func validationToken(for turn: AgentTranscriptTurn) -> AgentTranscriptTurnProjectionCache.ValidationToken {
		.init(
			turnID: turn.id,
			retentionTier: turn.retentionTier,
			isCompleted: turn.isCompleted,
			responseSpanCount: turn.responseSpans.count,
			activityCount: turn.allActivities.count,
			conclusionActivityID: turn.conclusionActivityID,
			frozenDetailedToolTailLimit: turn.frozenDetailedToolTailLimit
		)
	}

	private func turnID(for anchor: AgentTranscriptAnchor) -> UUID { anchor.turnID }

	private func cachedProjection(
		for turn: AgentTranscriptTurn,
		protectedTurnID: UUID?,
		turnCaches: [UUID: AgentTranscriptTurnProjectionCache]
	) -> AgentTranscriptTurnProjectionCache? {
		guard turn.isCompleted,
			turn.id != protectedTurnID,
			let cachedProjection = turnCaches[turn.id],
			cachedProjection.token == validationToken(for: turn)
		else {
			return nil
		}
		return cachedProjection
	}

	private func appendCachedProjectionState(
		_ cachedProjection: AgentTranscriptTurnProjectionCache,
		workingBlocks: inout [AgentTranscriptRenderBlock],
		archivedBlocks: inout [AgentTranscriptRenderBlock],
		workingRows: inout [AgentChatItem],
		archivedRows: inout [AgentChatItem],
		rowAnchorIndex: inout [UUID: AgentTranscriptAnchor],
		anchorBlockIndex: inout [AgentTranscriptAnchor: String]
	) {
		workingBlocks.append(contentsOf: cachedProjection.workingBlocks)
		archivedBlocks.append(contentsOf: cachedProjection.archivedBlocks)
		workingRows.append(contentsOf: cachedProjection.workingRows)
		archivedRows.append(contentsOf: cachedProjection.archivedRows)
		rowAnchorIndex.merge(cachedProjection.rowAnchorIndex) { _, new in new }
		anchorBlockIndex.merge(cachedProjection.anchorBlockIndex) { _, new in new }
	}

	private func projectionCache(
		for turn: AgentTranscriptTurn,
		token: AgentTranscriptTurnProjectionCache.ValidationToken,
		workingBlocks: [AgentTranscriptRenderBlock],
		archivedBlocks: [AgentTranscriptRenderBlock],
		workingRows: [AgentChatItem],
		archivedRows: [AgentChatItem],
		rowAnchorIndex: [UUID: AgentTranscriptAnchor],
		anchorBlockIndex: [AgentTranscriptAnchor: String]
	) -> AgentTranscriptTurnProjectionCache {
		AgentTranscriptTurnProjectionCache(
			token: token,
			workingBlocks: workingBlocks,
			archivedBlocks: archivedBlocks,
			workingRows: workingRows,
			archivedRows: archivedRows,
			rowAnchorIndex: rowAnchorIndex.filter { turnID(for: $0.value) == turn.id },
			anchorBlockIndex: anchorBlockIndex.filter { turnID(for: $0.key) == turn.id }
		)
	}

	private func projectionCache(
		for turn: AgentTranscriptTurn,
		token: AgentTranscriptTurnProjectionCache.ValidationToken,
		projection: AgentTranscriptProjection
	) -> AgentTranscriptTurnProjectionCache {
		let workingBlocks = projection.workingBlocks.filter { $0.turnID == turn.id }
		let archivedBlocks = projection.archivedBlocks.filter { $0.turnID == turn.id }
		return projectionCache(
			for: turn,
			token: token,
			workingBlocks: workingBlocks,
			archivedBlocks: archivedBlocks,
			workingRows: projectionRows(for: workingBlocks),
			archivedRows: projectionRows(for: archivedBlocks),
			rowAnchorIndex: projection.rowAnchorIndex,
			anchorBlockIndex: projection.anchorBlockIndex
		)
	}

	public func blocks(for turn: AgentTranscriptTurn, archived: Bool, isLatestTurn: Bool = true) -> [AgentTranscriptRenderBlock] {
		let context = AgentTranscriptProjectionBuildContext(services: services)
		return blocks(
			for: turn,
			archived: archived,
			isLatestTurn: isLatestTurn,
			context: context
		)
	}

	private func blocks(
		for turn: AgentTranscriptTurn,
		archived: Bool,
		isLatestTurn: Bool,
		context: AgentTranscriptProjectionBuildContext
	) -> [AgentTranscriptRenderBlock] {
		_ = isLatestTurn
		return blocksForTurn(
			turn,
			archived: archived,
			detailedToolTailLimit: effectiveDetailedToolTailLimit(for: turn),
			context: context,
			protectDetachedFocus: false
		)
	}

	public func blocks(for turn: AgentTranscriptTurn, archived: Bool, detailedToolTailLimit: Int) -> [AgentTranscriptRenderBlock] {
		let context = AgentTranscriptProjectionBuildContext(services: services)
		return blocksForTurn(
			turn,
			archived: archived,
			detailedToolTailLimit: detailedToolTailLimit,
			context: context,
			protectDetachedFocus: false
		)
	}

	public func normalizedFrozenDetailedToolTailLimits(in transcript: AgentTranscript) -> AgentTranscript {
		var updatedTranscript = transcript
		for index in updatedTranscript.turns.indices {
			guard updatedTranscript.turns[index].retentionTier == .full,
				updatedTranscript.turns[index].isCompleted
			else {
				updatedTranscript.turns[index].frozenDetailedToolTailLimit = nil
				continue
			}
			updatedTranscript.turns[index].frozenDetailedToolTailLimit =
				normalizedFrozenDetailedToolTailLimit(for: updatedTranscript.turns[index])
		}

		let detailedToolTailLimits = detailedToolTailLimits(for: updatedTranscript)
		for index in updatedTranscript.turns.indices {
			guard updatedTranscript.turns[index].retentionTier == .full,
				updatedTranscript.turns[index].isCompleted
			else {
				updatedTranscript.turns[index].frozenDetailedToolTailLimit = nil
				continue
			}
			let detailedToolTailLimit = detailedToolTailLimits[updatedTranscript.turns[index].id] ?? 0
			updatedTranscript.turns[index].frozenDetailedToolTailLimit = groupedHistoryWouldCollapse(
				in: updatedTranscript.turns[index],
				detailedToolTailLimit: detailedToolTailLimit
			) ? detailedToolTailLimit : nil
		}
		return updatedTranscript
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public func groupedHistoryWouldCollapse(
		in turn: AgentTranscriptTurn,
		detailedToolTailLimit: Int
	) -> Bool {
		guard turn.retentionTier == .full else { return false }
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			let leafBlocks = fullSpanLeafBlocks(
				for: span,
				in: turn,
				archived: false,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			if groupedHistoryCollapsePlan(
				in: leafBlocks,
				spanID: span.id,
				detailedToolTailLimit: detailedToolTailLimit
			) != nil {
				return true
			}
		}
		return false
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public func normalizedFrozenDetailedToolTailLimit(for turn: AgentTranscriptTurn) -> Int? {
		guard turn.retentionTier == .full,
			turn.isCompleted,
			let rawFrozen = turn.frozenDetailedToolTailLimit
		else {
			return nil
		}
		let frozen = max(0, rawFrozen)
		guard standaloneToolBlockCount(for: turn) > frozen else { return nil }
		return groupedHistoryWouldCollapse(in: turn, detailedToolTailLimit: frozen) ? frozen : nil
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public func detailedToolTailLimits(for transcript: AgentTranscript) -> [UUID: Int] {
		var remainingBudget = Self.globalDetailedToolTailLimit
		var limits: [UUID: Int] = [:]

		for turn in transcript.turns.reversed() {
			guard turn.retentionTier == .full else {
				limits[turn.id] = 0
				continue
			}
			let visibleToolCeiling = normalizedFrozenDetailedToolTailLimit(for: turn)
				?? standaloneToolBlockCount(for: turn)
			let visibleToolCount = min(visibleToolCeiling, remainingBudget)
			limits[turn.id] = visibleToolCount
			remainingBudget = max(0, remainingBudget - visibleToolCount)
		}

		return limits
	}

	private func effectiveDetailedToolTailLimit(for turn: AgentTranscriptTurn) -> Int {
		guard turn.retentionTier == .full else { return 0 }
		if let frozen = normalizedFrozenDetailedToolTailLimit(for: turn) {
			return frozen
		}
		return min(standaloneToolBlockCount(for: turn), Self.globalDetailedToolTailLimit)
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public func standaloneToolBlockCount(for turn: AgentTranscriptTurn) -> Int {
		var emittedConclusionActivityIDs = Set<UUID>()
		return turn.responseSpans.reduce(into: 0) { partial, span in
			let kinds = fullSpanLeafBlockKinds(
				for: span,
				in: turn,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			partial += kinds.filter { $0 == .standaloneTool }.count
		}
	}

	private func blocksForTurn(
		_ turn: AgentTranscriptTurn,
		archived: Bool,
		detailedToolTailLimit: Int,
		context: AgentTranscriptProjectionBuildContext,
		protectDetachedFocus: Bool
	) -> [AgentTranscriptRenderBlock] {
		let unsortedBlocks: [AgentTranscriptRenderBlock]
		if protectDetachedFocus, turn.retentionTier != .archived {
			unsortedBlocks = fullBlocks(
				for: turn,
				archived: archived,
				detailedToolTailLimit: standaloneToolBlockCount(for: turn),
				context: context
			)
		} else {
			switch turn.retentionTier {
			case .full:
				unsortedBlocks = fullBlocks(
					for: turn,
					archived: archived,
					detailedToolTailLimit: detailedToolTailLimit,
					context: context
				)
			case .condensed, .summary:
				unsortedBlocks = compactTierBlocks(
					for: turn,
					archived: archived,
					context: context
				)
			case .archived:
				unsortedBlocks = compactedBlocks(for: turn, archived: archived)
			}
		}
		return unsortedBlocks.enumerated().sorted { lhs, rhs in
			let lhsSequence = blockSequenceIndex(lhs.element)
			let rhsSequence = blockSequenceIndex(rhs.element)
			if lhsSequence == rhsSequence {
				return lhs.offset < rhs.offset
			}
			return lhsSequence < rhsSequence
		}.map(\.element)
	}

	private func blockSequenceIndex(_ block: AgentTranscriptRenderBlock) -> Int {
		if let rowSequence = block.rows.map(\.sequenceIndex).min() {
			return rowSequence
		}
		if let groupedHistory = block.groupedHistory {
			let childSequences = groupedHistory.sections
				.flatMap(\.childBlocks)
				.map(blockSequenceIndex)
			if let childSequence = childSequences.min() {
				return childSequence
			}
		}
		return Int.max
	}

	private func estimatedBlockCount(for turn: AgentTranscriptTurn, detailedToolTailLimit: Int) -> Int {
		switch turn.retentionTier {
		case .full:
			return estimatedFullBlockCount(for: turn, detailedToolTailLimit: detailedToolTailLimit)
		case .condensed, .summary:
			return compactTierBlockCount(for: turn)
		case .archived:
			return 0
		}
	}

	private func compactedVisibleRowCount(for turn: AgentTranscriptTurn) -> Int {
		compactedRows(for: turn).count
	}

	private func compactTierBlockCount(for turn: AgentTranscriptTurn) -> Int {
		var count = turn.request == nil ? 0 : 1
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			if span.activities.isEmpty {
				if span.collapsedSummary != nil {
					count += 1
				}
				continue
			}
			let leafDescriptors = fullSpanLeafDescriptors(
				for: span,
				in: turn,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			let contentCount = leafDescriptors.filter { $0.kind != .conclusion }.count
			let conclusionCount = leafDescriptors.filter { $0.kind == .conclusion }.count
			count += (contentCount > 0 ? 1 : 0) + conclusionCount
		}
		if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
			count += 1
		}
		return count
	}

	private func compactTierVisibleRowCount(for turn: AgentTranscriptTurn) -> Int {
		var count = turn.request == nil ? 0 : 1
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			if span.activities.isEmpty {
				if span.collapsedSummary != nil {
					count += 1
				}
				continue
			}
			let leafDescriptors = fullSpanLeafDescriptors(
				for: span,
				in: turn,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			if leafDescriptors.contains(where: { $0.kind != .conclusion }) {
				count += 1
			}
			count += leafDescriptors
				.filter { $0.kind == .conclusion }
				.reduce(0) { $0 + $1.rowCount }
		}
		if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
			count += 1
		}
		return count
	}

	private func compactedRows(for turn: AgentTranscriptTurn) -> [AgentChatItem] {
		var rows: [AgentChatItem] = []
		if let request = turn.request?.toItem() {
			rows.append(request)
		}
		if let summaryRow = middleSummaryRow(for: turn) {
			rows.append(summaryRow)
		}
		if let conclusionRow = conclusionRow(for: turn) {
			rows.append(conclusionRow)
		}
		return rows
	}

	private func estimatedFullBlockCount(for turn: AgentTranscriptTurn, detailedToolTailLimit: Int) -> Int {
		var count = turn.request == nil ? 0 : 1
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			count += estimatedFullSpanBlockCount(
				for: span,
				in: turn,
				detailedToolTailLimit: detailedToolTailLimit,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
		}
		if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
			count += 1
		}
		return count
	}

	private func fullTurnVisibleRowCount(
		for turn: AgentTranscriptTurn,
		detailedToolTailLimit: Int
	) -> Int {
		var count = turn.request == nil ? 0 : 1
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			let leafDescriptors = fullSpanLeafDescriptors(
				for: span,
				in: turn,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			count += collapsedVisibleRowCount(
				for: leafDescriptors,
				detailedToolTailLimit: detailedToolTailLimit
			)
		}
		if emittedConclusionActivityIDs.isEmpty, conclusionRow(for: turn) != nil {
			count += 1
		}
		return count
	}

	private func estimatedFullSpanBlockCount(
		for span: AgentTranscriptProviderResponseSpan,
		in turn: AgentTranscriptTurn,
		detailedToolTailLimit: Int,
		emittedConclusionActivityIDs: inout Set<UUID>
	) -> Int {
		let leafDescriptors = fullSpanLeafDescriptors(
			for: span,
			in: turn,
			emittedConclusionActivityIDs: &emittedConclusionActivityIDs
		)
		return collapsedBlockCount(for: leafDescriptors, detailedToolTailLimit: detailedToolTailLimit)
	}

	private func fullSpanLeafBlockKinds(
		for span: AgentTranscriptProviderResponseSpan,
		in turn: AgentTranscriptTurn,
		emittedConclusionActivityIDs: inout Set<UUID>
	) -> [AgentTranscriptRenderBlockKind] {
		let orderedActivities = span.activities.sorted { lhs, rhs in
			if lhs.sequenceIndex == rhs.sequenceIndex {
				return lhs.timestamp < rhs.timestamp
			}
			return lhs.sequenceIndex < rhs.sequenceIndex
		}
		var kinds: [AgentTranscriptRenderBlockKind] = []
		var currentToolExecutionID: String?
		for activity in orderedActivities {
			guard !isSuppressedActivity(activity) else { continue }
			switch classify(activity: activity, in: turn) {
			case .conclusion:
				currentToolExecutionID = nil
				if emittedConclusionActivityIDs.insert(activity.id).inserted {
					kinds.append(.conclusion)
				}
			case .standaloneTool:
				let stableExecutionID = activity.toolExecution?.stableExecutionID
				if currentToolExecutionID != stableExecutionID {
					kinds.append(.standaloneTool)
					currentToolExecutionID = stableExecutionID
				}
			case .standaloneAssistant:
				currentToolExecutionID = nil
				kinds.append(.standaloneAssistant)
			case .standaloneNote:
				currentToolExecutionID = nil
				kinds.append(.standaloneNote)
			}
		}
		return kinds
	}

	private func fullSpanLeafDescriptors(
		for span: AgentTranscriptProviderResponseSpan,
		in turn: AgentTranscriptTurn,
		emittedConclusionActivityIDs: inout Set<UUID>
	) -> [CollapsibleLeafDescriptor] {
		let orderedActivities = span.activities.sorted { lhs, rhs in
			if lhs.sequenceIndex == rhs.sequenceIndex {
				return lhs.timestamp < rhs.timestamp
			}
			return lhs.sequenceIndex < rhs.sequenceIndex
		}
		var descriptors: [CollapsibleLeafDescriptor] = []
		var currentToolExecutionID: String?
		var currentToolRowCount = 0

		func flushStandaloneToolDescriptor() {
			guard currentToolRowCount > 0 else { return }
			descriptors.append(.init(kind: .standaloneTool, rowCount: currentToolRowCount))
			currentToolExecutionID = nil
			currentToolRowCount = 0
		}

		for activity in orderedActivities {
			guard !isSuppressedActivity(activity) else { continue }
			switch classify(activity: activity, in: turn) {
			case .conclusion:
				flushStandaloneToolDescriptor()
				if emittedConclusionActivityIDs.insert(activity.id).inserted {
					descriptors.append(.init(kind: .conclusion, rowCount: 1))
				}
			case .standaloneTool:
				let stableExecutionID = activity.toolExecution?.stableExecutionID
				if currentToolRowCount > 0,
					currentToolExecutionID == stableExecutionID {
					currentToolRowCount += 1
				} else {
					flushStandaloneToolDescriptor()
					currentToolExecutionID = stableExecutionID
					currentToolRowCount = 1
				}
			case .standaloneAssistant:
				flushStandaloneToolDescriptor()
				descriptors.append(.init(
					kind: .standaloneAssistant,
					rowCount: 1
				))
			case .standaloneNote:
				flushStandaloneToolDescriptor()
				descriptors.append(.init(
					kind: .standaloneNote,
					rowCount: 1,
					containsProgressNote: activity.itemKind == .thinking
				))
			}
		}

		flushStandaloneToolDescriptor()
		return descriptors
	}

	private func collapsedBlockCount(
		for leafDescriptors: [CollapsibleLeafDescriptor],
		detailedToolTailLimit: Int
	) -> Int {
		collapsedPresentationMetrics(
			for: leafDescriptors,
			detailedToolTailLimit: detailedToolTailLimit
		).visibleBlockCount
	}

	private func collapsedVisibleRowCount(
		for leafDescriptors: [CollapsibleLeafDescriptor],
		detailedToolTailLimit: Int
	) -> Int {
		collapsedPresentationMetrics(
			for: leafDescriptors,
			detailedToolTailLimit: detailedToolTailLimit
		).visibleRowCount
	}

	private struct CollapsedPresentationMetrics {
		let visibleBlockCount: Int
		let visibleRowCount: Int
	}

	private func collapsedPresentationMetrics(
		for leafDescriptors: [CollapsibleLeafDescriptor],
		detailedToolTailLimit: Int
	) -> CollapsedPresentationMetrics {
		let conclusionDescriptors = leafDescriptors.filter { $0.kind == .conclusion }
		let conclusionBlockCount = conclusionDescriptors.count
		let conclusionRowCount = conclusionDescriptors.reduce(0) { $0 + $1.rowCount }
		let contentDescriptors = leafDescriptors.filter { $0.kind != .conclusion }
		let toolIndices = contentDescriptors.indices.filter { contentDescriptors[$0].kind == .standaloneTool }
		guard !toolIndices.isEmpty else {
			return .init(
				visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
				visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
			)
		}

		let detailedStartIndex: Int
		if detailedToolTailLimit <= 0 {
			detailedStartIndex = contentDescriptors.count
		} else {
			guard toolIndices.count > detailedToolTailLimit else {
				return .init(
					visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
					visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
				)
			}
			let firstKeptToolIndex = toolIndices[toolIndices.count - detailedToolTailLimit]
			var computedDetailedStartIndex = firstKeptToolIndex
			while computedDetailedStartIndex > 0 {
				let previousDescriptor = contentDescriptors[computedDetailedStartIndex - 1]
				if previousDescriptor.kind == .standaloneTool {
					break
				}
				computedDetailedStartIndex -= 1
			}
			detailedStartIndex = computedDetailedStartIndex
		}

		let collapsedPrefix = contentDescriptors.prefix(detailedStartIndex)
		let detailedSuffix = contentDescriptors.dropFirst(detailedStartIndex)
		guard !collapsedPrefix.isEmpty else {
			return .init(
				visibleBlockCount: contentDescriptors.count + conclusionBlockCount,
				visibleRowCount: contentDescriptors.reduce(0) { $0 + $1.rowCount } + conclusionRowCount
			)
		}

		let bufferedLeadingDescriptor = shouldBufferLeadingAssistant(in: collapsedPrefix)
			? collapsedPrefix.first
			: nil
		return .init(
			visibleBlockCount: 1 + (bufferedLeadingDescriptor == nil ? 0 : 1) + detailedSuffix.count + conclusionBlockCount,
			visibleRowCount: 1
				+ (bufferedLeadingDescriptor?.rowCount ?? 0)
				+ detailedSuffix.reduce(0) { $0 + $1.rowCount }
				+ conclusionRowCount
		)
	}

	private func filteredRowAnchorIndex(
		_ index: [UUID: AgentTranscriptAnchor],
		retaining rowIDs: Set<UUID>
	) -> [UUID: AgentTranscriptAnchor] {
		guard !index.isEmpty, !rowIDs.isEmpty else { return [:] }
		return index.filter { rowIDs.contains($0.key) }
	}

	private func filteredAnchorBlockIndex(
		_ index: [AgentTranscriptAnchor: String],
		retaining blockIDs: Set<String>
	) -> [AgentTranscriptAnchor: String] {
		guard !index.isEmpty, !blockIDs.isEmpty else { return [:] }
		return index.filter { blockIDs.contains($0.value) }
	}

	private func presentedItemCount(for blocks: [AgentTranscriptRenderBlock]) -> Int {
		blocks.reduce(0) { partial, block in
			partial + presentedItemCount(for: block)
		}
	}

	private func presentedItemCount(for block: AgentTranscriptRenderBlock) -> Int {
		switch block.kind {
		case .activityCluster, .groupedHistory:
			return 1
		case .request, .standaloneAssistant, .standaloneTool, .standaloneNote, .middleSummary, .conclusion:
			return block.rows.count
		}
	}

	private func shouldBufferLeadingAssistant(
		in collapsedPrefix: [AgentTranscriptRenderBlock]
	) -> Bool {
		guard let firstCollapsed = collapsedPrefix.first,
			firstCollapsed.kind == .standaloneAssistant
		else {
			return false
		}
		return !collapsedPrefix.dropFirst().contains { block in
			block.kind == .standaloneNote && block.rows.contains(where: { $0.kind == .thinking })
		}
	}

	private func shouldBufferLeadingAssistant(
		in collapsedPrefix: ArraySlice<CollapsibleLeafDescriptor>
	) -> Bool {
		guard let firstCollapsed = collapsedPrefix.first,
			firstCollapsed.kind == .standaloneAssistant
		else {
			return false
		}
		return !collapsedPrefix.dropFirst().contains(where: \.containsProgressNote)
	}

	private func groupedHistoryCollapsePlan(
		in leafBlocks: [AgentTranscriptRenderBlock],
		spanID: UUID,
		detailedToolTailLimit: Int
	) -> GroupedHistoryCollapsePlan? {
		let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
		let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
		let toolIndices = contentBlocks.indices.filter { contentBlocks[$0].kind == .standaloneTool }
		guard !toolIndices.isEmpty else { return nil }

		let collapsedPrefix: [AgentTranscriptRenderBlock]
		let detailedSuffix: [AgentTranscriptRenderBlock]
		if detailedToolTailLimit <= 0 {
			collapsedPrefix = contentBlocks
			detailedSuffix = []
		} else {
			guard toolIndices.count > detailedToolTailLimit else { return nil }
			let firstKeptToolIndex = toolIndices[toolIndices.count - detailedToolTailLimit]
			var detailedStartIndex = firstKeptToolIndex
			while detailedStartIndex > 0 {
				let previousBlock = contentBlocks[detailedStartIndex - 1]
				if previousBlock.kind == .standaloneTool || previousBlock.spanID != spanID {
					break
				}
				detailedStartIndex -= 1
			}
			collapsedPrefix = Array(contentBlocks.prefix(detailedStartIndex))
			detailedSuffix = Array(contentBlocks.dropFirst(detailedStartIndex))
		}
		guard !collapsedPrefix.isEmpty else { return nil }

		let bufferedLeadingAssistant: AgentTranscriptRenderBlock?
		let groupedPrefix: [AgentTranscriptRenderBlock]
		if shouldBufferLeadingAssistant(in: collapsedPrefix),
			let firstCollapsed = collapsedPrefix.first {
			bufferedLeadingAssistant = firstCollapsed
			groupedPrefix = Array(collapsedPrefix.dropFirst())
		} else {
			bufferedLeadingAssistant = nil
			groupedPrefix = collapsedPrefix
		}
		guard !groupedPrefix.isEmpty else { return nil }

		return GroupedHistoryCollapsePlan(
			contentBlocks: contentBlocks,
			conclusionBlocks: conclusionBlocks,
			collapsedPrefix: collapsedPrefix,
			groupedPrefix: groupedPrefix,
			detailedSuffix: detailedSuffix,
			bufferedLeadingAssistant: bufferedLeadingAssistant,
			collapseDigest: groupedHistoryCollapseDigest(
				for: collapsedPrefix,
				detailedToolTailLimit: detailedToolTailLimit
			)
		)
	}

	private func groupedHistoryCollapseDigest(
		for collapsedPrefix: [AgentTranscriptRenderBlock],
		detailedToolTailLimit: Int
	) -> String {
		let blockSignature = collapsedPrefix.map { block in
			let activityIDs = block.activityIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
			return "\(block.kind.rawValue)|\(block.id)|\(activityIDs)"
		}.joined(separator: ";")
		return "tail:\(detailedToolTailLimit)#\(blockSignature)"
	}

	private func requestBlockID(_ requestID: UUID) -> String {
		"block-\(requestID.uuidString.lowercased())"
	}

	private func requestAnchor(for turnID: UUID) -> AgentTranscriptAnchor {
		.request(turnID: turnID)
	}

	private func summaryAnchor(for turnID: UUID) -> AgentTranscriptAnchor {
		.summary(turnID: turnID)
	}

	private func groupedHistoryAnchor(for turnID: UUID, spanID: UUID) -> AgentTranscriptAnchor {
		.groupedHistory(turnID: turnID, spanID: spanID)
	}

	private func activityAnchor(for activityID: UUID, turnID: UUID, spanID: UUID) -> AgentTranscriptAnchor {
		.activity(turnID: turnID, spanID: spanID, activityID: activityID)
	}

	private func conclusionAnchor(for activityID: UUID, turnID: UUID) -> AgentTranscriptAnchor {
		.conclusion(turnID: turnID, activityID: activityID)
	}

	private func semanticAnchor(for activityID: UUID, in turn: AgentTranscriptTurn, spanID: UUID) -> AgentTranscriptAnchor {
		if activityID == turn.conclusionActivityID {
			return conclusionAnchor(for: activityID, turnID: turn.id)
		}
		return activityAnchor(for: activityID, turnID: turn.id, spanID: spanID)
	}

	private func activityBlockID(_ activityID: UUID?, fallback turnID: UUID) -> String {
		"block-\((activityID ?? turnID).uuidString.lowercased())"
	}

	private func groupedHistoryBlockID(turnID: UUID, spanID: UUID) -> String {
		"grouped-history:\(turnID.uuidString.lowercased()):\(spanID.uuidString.lowercased())"
	}

	private func summaryBlockID(_ summaryID: UUID) -> String {
		"block-\(summaryID.uuidString.lowercased())"
	}

	// internal (was fileprivate): shared across the 2026-07-16 capability split.
	public static let globalDetailedToolTailLimit = 8

	private enum ActivityRenderClass {
		case conclusion
		case standaloneAssistant
		case standaloneTool
		case standaloneNote
	}

	private func fullBlocks(
		for turn: AgentTranscriptTurn,
		archived: Bool,
		detailedToolTailLimit: Int,
		context: AgentTranscriptProjectionBuildContext
	) -> [AgentTranscriptRenderBlock] {
		var blocks: [AgentTranscriptRenderBlock] = []
		if let request = turn.request {
			blocks.append(.init(
				id: requestBlockID(request.id),
				kind: .request,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [request.toItem()],
				isArchived: archived,
				primaryAnchor: requestAnchor(for: turn.id)
			))
		}
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			let leafBlocks = fullSpanLeafBlocks(
				for: span,
				in: turn,
				archived: archived,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			blocks.append(contentsOf: collapseOlderHistory(
				in: leafBlocks,
				span: span,
				turn: turn,
				spanID: span.id,
				archived: archived,
				detailedToolTailLimit: detailedToolTailLimit,
				context: context
			))
		}
		if emittedConclusionActivityIDs.isEmpty,
			let conclusionRow = conclusionRow(for: turn) {
			blocks.append(.init(
				id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
				kind: .conclusion,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [conclusionRow],
				isArchived: archived,
				primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
				anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
				activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
			))
		}
		return blocks
	}

	private func compactTierBlocks(
		for turn: AgentTranscriptTurn,
		archived: Bool,
		context: AgentTranscriptProjectionBuildContext
	) -> [AgentTranscriptRenderBlock] {
		var blocks: [AgentTranscriptRenderBlock] = []
		if let request = turn.request {
			blocks.append(.init(
				id: requestBlockID(request.id),
				kind: .request,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [request.toItem()],
				isArchived: archived,
				primaryAnchor: requestAnchor(for: turn.id)
			))
		}
		var emittedConclusionActivityIDs = Set<UUID>()
		for span in turn.responseSpans {
			if span.activities.isEmpty {
				if let collapsedSummary = span.collapsedSummary {
					blocks.append(groupedHistoryBlock(
						for: [],
						frozenSummary: collapsedSummary,
						turn: turn,
						spanID: span.id,
						archived: archived,
						context: context
					))
				}
				continue
			}
			let leafBlocks = fullSpanLeafBlocks(
				for: span,
				in: turn,
				archived: archived,
				emittedConclusionActivityIDs: &emittedConclusionActivityIDs
			)
			let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
			let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
			if !contentBlocks.isEmpty {
				blocks.append(groupedHistoryBlock(
					for: contentBlocks,
					frozenSummary: span.collapsedSummary,
					turn: turn,
					spanID: span.id,
					archived: archived,
					context: context
				))
			}
			blocks.append(contentsOf: conclusionBlocks)
		}
		if emittedConclusionActivityIDs.isEmpty,
			let conclusionRow = conclusionRow(for: turn) {
			blocks.append(.init(
				id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
				kind: .conclusion,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [conclusionRow],
				isArchived: archived,
				primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
				anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
				activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
			))
		}
		return blocks
	}

	private func compactedBlocks(for turn: AgentTranscriptTurn, archived: Bool) -> [AgentTranscriptRenderBlock] {
		var blocks: [AgentTranscriptRenderBlock] = []
		if let request = turn.request {
			blocks.append(.init(
				id: requestBlockID(request.id),
				kind: .request,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [request.toItem()],
				isArchived: archived,
				primaryAnchor: requestAnchor(for: turn.id)
			))
		}
		if let summaryRow = middleSummaryRow(for: turn) {
			blocks.append(.init(
				id: summaryBlockID(summaryRow.id),
				kind: .middleSummary,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [summaryRow],
				isArchived: archived,
				primaryAnchor: summaryAnchor(for: turn.id),
				anchorActivityID: summaryRow.id,
				activityIDs: [summaryRow.id]
			))
		}
		if let conclusionRow = conclusionRow(for: turn) {
			blocks.append(.init(
				id: activityBlockID(turn.conclusionActivityID ?? conclusionRow.id, fallback: turn.id),
				kind: .conclusion,
				turnID: turn.id,
				retentionTier: turn.retentionTier,
				rows: [conclusionRow],
				isArchived: archived,
				primaryAnchor: conclusionAnchor(for: turn.conclusionActivityID ?? conclusionRow.id, turnID: turn.id),
				anchorActivityID: turn.conclusionActivityID ?? conclusionRow.id,
				activityIDs: turn.conclusionActivityID.map { [$0] } ?? [conclusionRow.id]
			))
		}
		return blocks
	}

	private func classify(activity: AgentTranscriptActivity, in turn: AgentTranscriptTurn) -> ActivityRenderClass {
		if activity.id == turn.conclusionActivityID {
			return .conclusion
		}
		switch activity.itemKind {
		case .assistant, .assistantInline:
			return .standaloneAssistant
		case .toolCall, .toolResult:
			return .standaloneTool
		case .thinking, .system:
			return .standaloneNote
		case .error, .user:
			return .standaloneNote
		}
	}

	private func fullSpanLeafBlocks(
		for span: AgentTranscriptProviderResponseSpan,
		in turn: AgentTranscriptTurn,
		archived: Bool,
		emittedConclusionActivityIDs: inout Set<UUID>
	) -> [AgentTranscriptRenderBlock] {
		let orderedActivities = span.activities.sorted { lhs, rhs in
			if lhs.sequenceIndex == rhs.sequenceIndex {
				return lhs.timestamp < rhs.timestamp
			}
			return lhs.sequenceIndex < rhs.sequenceIndex
		}
		var blocks: [AgentTranscriptRenderBlock] = []
		var standaloneToolActivities: [AgentTranscriptActivity] = []

		func flushStandaloneToolActivities() {
			guard !standaloneToolActivities.isEmpty else { return }
			blocks.append(standaloneToolBlock(
				for: standaloneToolActivities,
				turn: turn,
				spanID: span.id,
				archived: archived
			))
			standaloneToolActivities.removeAll(keepingCapacity: true)
		}

		for activity in orderedActivities {
			guard !isSuppressedActivity(activity) else { continue }
			let renderClass = classify(activity: activity, in: turn)
			if renderClass == .conclusion {
				flushStandaloneToolActivities()
				if emittedConclusionActivityIDs.insert(activity.id).inserted {
					blocks.append(conclusionBlock(
						for: activity,
						turn: turn,
						spanID: span.id,
						archived: archived
					))
				}
				continue
			}

			switch renderClass {
			case .standaloneTool:
				if standaloneToolActivities.first?.toolExecution?.stableExecutionID == activity.toolExecution?.stableExecutionID {
					standaloneToolActivities.append(activity)
				} else {
					flushStandaloneToolActivities()
					standaloneToolActivities.append(activity)
				}
			case .standaloneAssistant, .standaloneNote:
				flushStandaloneToolActivities()
				blocks.append(standaloneBlock(
					for: activity,
					renderClass: renderClass,
					turn: turn,
					spanID: span.id,
					archived: archived
				))
			case .conclusion:
				break
			}
		}

		flushStandaloneToolActivities()
		return blocks
	}

	private func isDisplaylessAssistant(_ activity: AgentTranscriptActivity) -> Bool {
		guard activity.itemKind == .assistant || activity.itemKind == .assistantInline else { return false }
		return !AgentDisplayableText.hasDisplayableBody(activity.text)
	}

	private func isSuppressedActivity(_ activity: AgentTranscriptActivity) -> Bool {
		isDisplaylessAssistant(activity) || services.suppressActivity(activity)
	}

	private func collapseOlderHistory(
		in leafBlocks: [AgentTranscriptRenderBlock],
		span: AgentTranscriptProviderResponseSpan,
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool,
		detailedToolTailLimit: Int,
		context: AgentTranscriptProjectionBuildContext
	) -> [AgentTranscriptRenderBlock] {
		guard !leafBlocks.isEmpty else { return [] }
		guard let plan = groupedHistoryCollapsePlan(
			in: leafBlocks,
			spanID: spanID,
			detailedToolTailLimit: detailedToolTailLimit
		) else {
			let conclusionBlocks = leafBlocks.filter { $0.kind == .conclusion }
			let contentBlocks = leafBlocks.filter { $0.kind != .conclusion }
			return contentBlocks + conclusionBlocks
		}

		var visibleBlocks: [AgentTranscriptRenderBlock] = []
		if let bufferedLeadingAssistant = plan.bufferedLeadingAssistant {
			visibleBlocks.append(bufferedLeadingAssistant)
		}
		if !plan.groupedPrefix.isEmpty {
			let frozenSummary: AgentTranscriptGroupedHistorySummary?
			if let cache = span.fullRenderGroupedHistoryCache,
				cache.detailedToolTailLimit == detailedToolTailLimit,
				cache.collapseDigest == plan.collapseDigest {
				frozenSummary = cache.summary
			} else {
				frozenSummary = nil
			}
			visibleBlocks.append(groupedHistoryBlock(
				for: plan.groupedPrefix,
				summarySourceBlocks: plan.collapsedPrefix,
				frozenSummary: frozenSummary,
				turn: turn,
				spanID: spanID,
				archived: archived,
				context: context
			))
		}
		if !plan.detailedSuffix.isEmpty {
			visibleBlocks.append(contentsOf: plan.detailedSuffix)
		}
		return visibleBlocks + plan.conclusionBlocks
	}

	private func standaloneBlock(
		for activity: AgentTranscriptActivity,
		renderClass: ActivityRenderClass,
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool
	) -> AgentTranscriptRenderBlock {
		let kind: AgentTranscriptRenderBlockKind
		switch renderClass {
		case .standaloneAssistant:
			kind = .standaloneAssistant
		case .standaloneTool:
			kind = .standaloneTool
		case .standaloneNote:
			kind = .standaloneNote
		case .conclusion:
			kind = .standaloneNote
		}
		return .init(
			id: activityBlockID(activity.id, fallback: turn.id),
			kind: kind,
			turnID: turn.id,
			spanID: spanID,
			retentionTier: turn.retentionTier,
			rows: [activity.toItem()],
			isArchived: archived,
			primaryAnchor: semanticAnchor(for: activity.id, in: turn, spanID: spanID),
			anchorActivityID: activity.id,
			activityIDs: [activity.id]
		)
	}

	private func activityClusterBlock(
		for childBlocks: [AgentTranscriptRenderBlock],
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool,
		context: AgentTranscriptProjectionBuildContext
	) -> AgentTranscriptRenderBlock {
		let rows = childBlocks.flatMap(\.rows)
		let allActivityIDs = childBlocks.flatMap(\.activityIDs)
		let anchorActivityID = allActivityIDs.first
		return .init(
			id: activityBlockID(anchorActivityID, fallback: turn.id),
			kind: .activityCluster,
			turnID: turn.id,
			spanID: spanID,
			retentionTier: turn.retentionTier,
			rows: rows,
			isArchived: archived,
			primaryAnchor: childBlocks.first?.primaryAnchor,
			anchorActivityID: anchorActivityID,
			activityIDs: allActivityIDs,
			clusterSummary: clusterSummary(for: rows, context: context),
			defaultPresentation: .collapsed
		)
	}

	private func standaloneToolBlock(
		for activities: [AgentTranscriptActivity],
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool
	) -> AgentTranscriptRenderBlock {
		let rows = activities.map { $0.toItem() }
		let anchorActivityID = activities.first?.id
		return .init(
			id: activityBlockID(anchorActivityID, fallback: turn.id),
			kind: .standaloneTool,
			turnID: turn.id,
			spanID: spanID,
			retentionTier: turn.retentionTier,
			rows: rows,
			isArchived: archived,
			primaryAnchor: anchorActivityID.map { semanticAnchor(for: $0, in: turn, spanID: spanID) },
			anchorActivityID: anchorActivityID,
			activityIDs: activities.map(\.id)
		)
	}

	private func groupedHistoryBlock(
		for childBlocks: [AgentTranscriptRenderBlock],
		summarySourceBlocks: [AgentTranscriptRenderBlock]? = nil,
		frozenSummary: AgentTranscriptGroupedHistorySummary? = nil,
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool,
		context: AgentTranscriptProjectionBuildContext
	) -> AgentTranscriptRenderBlock {
		let allActivityIDs = childBlocks.flatMap(\.activityIDs)
		let summaryBlocks = summarySourceBlocks ?? childBlocks
		let presentationSummary = frozenSummary.map(services.sanitizeGroupedSummary)
		return .init(
			id: groupedHistoryBlockID(turnID: turn.id, spanID: spanID),
			kind: .groupedHistory,
			turnID: turn.id,
			spanID: spanID,
			retentionTier: turn.retentionTier,
			rows: [],
			isArchived: archived,
			primaryAnchor: groupedHistoryAnchor(for: turn.id, spanID: spanID),
			anchorActivityID: allActivityIDs.first,
			activityIDs: allActivityIDs,
			groupedHistory: .init(
				summary: presentationSummary ?? groupedHistorySummary(
					for: childBlocks,
					summarySourceBlocks: summaryBlocks,
					context: context
				),
				sections: turn.retentionTier == .full
					? groupedHistorySections(
						for: childBlocks,
						spanID: spanID,
						context: context
					)
					: []
			),
			defaultPresentation: .collapsed
		)
	}

	private func conclusionBlock(
		for activity: AgentTranscriptActivity,
		turn: AgentTranscriptTurn,
		spanID: UUID,
		archived: Bool
	) -> AgentTranscriptRenderBlock {
		.init(
			id: activityBlockID(activity.id, fallback: turn.id),
			kind: .conclusion,
			turnID: turn.id,
			spanID: spanID,
			retentionTier: turn.retentionTier,
			rows: [activity.toItem(isStreaming: false)],
			isArchived: archived,
			primaryAnchor: conclusionAnchor(for: activity.id, turnID: turn.id),
			anchorActivityID: activity.id,
			activityIDs: [activity.id]
		)
	}

	private func groupedHistorySummary(
		for childBlocks: [AgentTranscriptRenderBlock],
		summarySourceBlocks: [AgentTranscriptRenderBlock]? = nil,
		context: AgentTranscriptProjectionBuildContext
	) -> AgentTranscriptGroupedHistorySummary {
		let hiddenAssistantCount = childBlocks.reduce(0) { partial, block in
			partial + block.rows.filter(isDisplayableAssistant(_:)).count
		}
		let hiddenProgressCount = childBlocks.reduce(0) { partial, block in
			partial + block.rows.filter { $0.kind == .thinking }.count
		}
		let hiddenNoteCount = childBlocks.reduce(0) { partial, block in
			partial + block.rows.filter { $0.kind == .system || $0.kind == .error }.count
		}
		let summaryRows = (summarySourceBlocks ?? childBlocks).flatMap(\.rows)
		let summary = AgentTranscriptGroupedHistorySummary(
			hiddenToolCardCount: childBlocks.filter { $0.kind == .standaloneTool }.count,
			hiddenAssistantCount: hiddenAssistantCount,
			hiddenProgressCount: hiddenProgressCount,
			hiddenNoteCount: hiddenNoteCount,
			toolSummary: clusterSummary(for: summaryRows, context: context)
		)
		return AgentTranscriptGroupedHistorySummary(
			hiddenToolCardCount: summary.hiddenToolCardCount,
			hiddenAssistantCount: summary.hiddenAssistantCount,
			hiddenProgressCount: summary.hiddenProgressCount,
			hiddenNoteCount: summary.hiddenNoteCount,
			toolSummary: summary.toolSummary,
			collapsedDisplay: services.groupedDisplay(summary)
		)
	}

	private func groupedHistorySections(
		for childBlocks: [AgentTranscriptRenderBlock],
		spanID: UUID,
		context: AgentTranscriptProjectionBuildContext
	) -> [AgentTranscriptGroupedSection] {
		guard !childBlocks.isEmpty else { return [] }
		var sections: [AgentTranscriptGroupedSection] = []
		var currentBlocks: [AgentTranscriptRenderBlock] = []

		func flushSection() {
			guard !currentBlocks.isEmpty else { return }
			let kind = groupedSectionKind(for: currentBlocks)
			let firstChildID = currentBlocks.first?.id ?? UUID().uuidString.lowercased()
			let summary = currentBlocks.contains(where: { $0.kind == .standaloneTool })
				? clusterSummary(for: currentBlocks.flatMap(\.rows), context: context)
				: nil
			let titleAndIcon = services.sectionTitleAndIcon(kind, summary)
			sections.append(.init(
				id: "grouped-section:\(spanID.uuidString.lowercased()):\(firstChildID)",
				kind: kind,
				title: titleAndIcon.title,
				icon: titleAndIcon.icon,
				childBlocks: currentBlocks,
				clusterSummary: summary
			))
			currentBlocks.removeAll(keepingCapacity: true)
		}

		for block in childBlocks {
			if shouldStartNewGroupedSection(currentBlocks: currentBlocks, nextBlock: block) {
				flushSection()
			}
			currentBlocks.append(block)
		}
		flushSection()
		return sections
	}

	private func shouldStartNewGroupedSection(
		currentBlocks: [AgentTranscriptRenderBlock],
		nextBlock: AgentTranscriptRenderBlock
	) -> Bool {
		guard let currentBlock = currentBlocks.last else { return false }
		return groupedSectionAffinity(for: currentBlock) != groupedSectionAffinity(for: nextBlock)
	}

	private func groupedSectionAffinity(for block: AgentTranscriptRenderBlock) -> GroupedSectionAffinity {
		switch block.kind {
		case .standaloneTool, .standaloneAssistant:
			return .activity
		case .standaloneNote:
			return block.rows.contains(where: { $0.kind == .thinking }) ? .activity : .notes
		case .request, .activityCluster, .groupedHistory, .middleSummary, .conclusion:
			return .mixed
		}
	}

	private func groupedSectionKind(for childBlocks: [AgentTranscriptRenderBlock]) -> AgentTranscriptGroupedSectionKind {
		var containsTools = false
		var containsAssistant = false
		var containsProgress = false
		var containsNotes = false
		var containsMixed = false

		for block in childBlocks {
			switch block.kind {
			case .standaloneTool:
				containsTools = true
			case .standaloneAssistant:
				containsAssistant = true
			case .standaloneNote:
				if block.rows.contains(where: { $0.kind == .thinking }) {
					containsProgress = true
				} else {
					containsNotes = true
				}
			case .request, .activityCluster, .groupedHistory, .middleSummary, .conclusion:
				containsMixed = true
			}
		}

		if containsMixed || containsNotes {
			if containsNotes && !containsMixed && !containsTools && !containsAssistant && !containsProgress {
				return .notes
			}
			return .mixed
		}
		if containsTools {
			return .tools
		}
		if containsAssistant && containsProgress {
			return .mixed
		}
		if containsAssistant {
			return .assistant
		}
		if containsProgress {
			return .progress
		}
		return .mixed
	}

	private enum GroupedSectionAffinity {
		case activity
		case notes
		case mixed
	}

	private func clusterSummary(
		for rows: [AgentChatItem],
		context: AgentTranscriptProjectionBuildContext
	) -> AgentTranscriptClusterSummary? {
		guard !rows.isEmpty else { return nil }
		let cacheKey = ClusterSummaryCacheKey(rowIDs: rows.map(\.id))
		if let cached = context.clusterSummaryByRowIDs[cacheKey] {
			return cached
		}
		let groupedExecutions = Dictionary(grouping: rows.compactMap { row -> (AgentChatItem, AgentTranscriptToolExecution)? in
			guard let execution = context.toolProcessor(row) else { return nil }
			return (row, execution)
		}, by: { $0.1.stableExecutionID })
		let orderedExecutionGroups = groupedExecutions.values
			.map { grouped in
				grouped.sorted { lhs, rhs in
					if lhs.0.sequenceIndex == rhs.0.sequenceIndex {
						return lhs.0.timestamp < rhs.0.timestamp
					}
					return lhs.0.sequenceIndex < rhs.0.sequenceIndex
				}
			}
			.sorted { lhs, rhs in
				guard let lhsLast = lhs.last?.0 else { return false }
				guard let rhsLast = rhs.last?.0 else { return true }
				if lhsLast.sequenceIndex == rhsLast.sequenceIndex {
					if lhsLast.timestamp == rhsLast.timestamp {
						return lhsLast.id.uuidString < rhsLast.id.uuidString
					}
					return lhsLast.timestamp < rhsLast.timestamp
				}
				return lhsLast.sequenceIndex < rhsLast.sequenceIndex
			}
		let toolExecutions: [AgentTranscriptToolExecution] = orderedExecutionGroups.compactMap { orderedGroup in
			guard let latestExecution = orderedGroup.last?.1 else { return nil }
			return orderedGroup.dropLast().reduce(latestExecution) { partial, entry in
				AgentTranscriptExecutionMetadata.merged(partial, with: entry.1)
			}
		}
		let toolNames = Array(NSOrderedSet(array: toolExecutions.compactMap {
			let normalized = services.normalizedToolName($0.toolName) ?? ""
			return normalized.isEmpty ? nil : normalized
		})) as? [String] ?? []
		var toolNameCounts: [String: Int] = [:]
		for exec in toolExecutions {
			let normalized = services.normalizedToolName(exec.toolName) ?? ""
			if !normalized.isEmpty {
				toolNameCounts[normalized, default: 0] += 1
			}
		}
		let keyPaths = Array(NSOrderedSet(array: toolExecutions.flatMap(\.keyPaths))) as? [String] ?? []
		let containsRunningWork = toolExecutions.contains { $0.status == .running || $0.status == .pending }
		let containsFailure = toolExecutions.contains { $0.status == .failed || $0.status == .cancelled }
		let containsWarning = toolExecutions.contains { $0.status == .warning }
		let narration = latestNarrationText(from: rows)
		let shortNarration: String?
		if let narration, !narration.isEmpty {
			shortNarration = narration.count > 120 ? String(narration.prefix(120)) + "…" : narration
		} else {
			shortNarration = nil
		}
		let allToolNames = toolNameCounts.isEmpty ? Array(toolNames) : Array(toolNameCounts.keys.sorted())
		let toolGroups = services.buildToolGroups(allToolNames, toolNameCounts)
		let summary = AgentTranscriptClusterSummary(
			toolCount: toolExecutions.count,
			toolNames: Array(toolNames.prefix(6)),
			toolNameCounts: toolNameCounts,
			toolGroups: toolGroups,
			keyPaths: Array(keyPaths.prefix(6)),
			containsRunningWork: containsRunningWork,
			containsFailure: containsFailure,
			containsWarning: containsWarning,
			shortNarration: shortNarration
		)
		let renderedSummary = AgentTranscriptClusterSummary(
			toolCount: summary.toolCount,
			toolNames: summary.toolNames,
			toolNameCounts: summary.toolNameCounts,
			toolGroups: summary.toolGroups,
			keyPaths: summary.keyPaths,
			containsRunningWork: summary.containsRunningWork,
			containsFailure: summary.containsFailure,
			containsWarning: summary.containsWarning,
			shortNarration: summary.shortNarration,
			collapsedDisplay: services.clusterDisplay(summary, summary.toolCount)
		)
		context.clusterSummaryByRowIDs[cacheKey] = renderedSummary
		return renderedSummary
	}

	private func latestNarrationText(from rows: [AgentChatItem]) -> String? {
		let latestAssistantText = rows.reversed().first(where: {
			isDisplayableAssistant($0)
		})?.text.trimmingCharacters(in: .whitespacesAndNewlines)
		if let latestAssistantText {
			return latestAssistantText
		}

		let latestThinkingText = rows.reversed().first(where: {
			$0.kind == .thinking
		})?.text.trimmingCharacters(in: .whitespacesAndNewlines)
		if let latestThinkingText, !latestThinkingText.isEmpty {
			return latestThinkingText
		}
		return nil
	}

	private func middleSummaryRow(for turn: AgentTranscriptTurn) -> AgentChatItem? {
		guard let summary = turn.summary,
			let text = summary.middleSummaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
			!text.isEmpty
		else {
			return nil
		}
		let requestSequence = turn.request?.sequenceIndex ?? (turn.allActivities.first?.sequenceIndex ?? 0)
		let conclusionSequence = conclusionRow(for: turn)?.sequenceIndex ?? (turn.allActivities.last?.sequenceIndex ?? requestSequence + 1)
		let sequenceIndex = min(conclusionSequence - 1, requestSequence + 1)
		return AgentChatItem(
			id: summary.middleSummaryItemID,
			timestamp: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt,
			kind: .system,
			text: text,
			sequenceIndex: max(sequenceIndex, requestSequence),
			isStreaming: false
		)
	}

	private func conclusionRow(for turn: AgentTranscriptTurn) -> AgentChatItem? {
		if let conclusionActivityID = turn.conclusionActivityID,
			let activity = turn.allActivities.first(where: { $0.id == conclusionActivityID }) {
			let text: String?
			switch turn.retentionTier {
			case .full, .condensed:
				text = displayableAssistantText(activity.text)
			case .summary, .archived:
				text = displayableAssistantText(turn.summary?.compactConclusionText)
					?? displayableAssistantText(turn.summary?.conclusionText)
					?? displayableAssistantText(activity.text)
			}
			if let text {
				return activity.toItem(text: text, isStreaming: false)
			}
		}
		guard let summary = turn.summary,
			let text = displayableAssistantText(summary.compactConclusionText) ?? displayableAssistantText(summary.conclusionText)
		else {
			return nil
		}
		let sequenceIndex = max(turn.request?.sequenceIndex ?? 0, (turn.allActivities.last?.sequenceIndex ?? 0) + 1)
		return AgentChatItem(
			id: AgentTranscriptIdentity.conclusionID(for: turn.id),
			timestamp: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt,
			kind: .assistant,
			text: text,
			sequenceIndex: sequenceIndex,
			isStreaming: false
		)
	}

    private func isDisplayableAssistant(_ item: AgentChatItem) -> Bool {
        (item.kind == .assistant || item.kind == .assistantInline) && AgentDisplayableText.hasDisplayableBody(item.text)
    }

	private func displayableAssistantText(_ text: String?) -> String? {
		guard let text,
			AgentDisplayableText.hasDisplayableBody(text) else {
			return nil
		}
		return text
	}

	private func registerAnchors(
		for turn: AgentTranscriptTurn,
		blocks: [AgentTranscriptRenderBlock],
		into index: inout [UUID: AgentTranscriptAnchor]
	) {
		if let request = turn.request {
			index[request.id] = .request(turnID: turn.id)
		}
		for span in turn.responseSpans {
			for activity in span.activities {
				guard !isSuppressedActivity(activity) else { continue }
				if activity.id == turn.conclusionActivityID {
					index[activity.id] = .conclusion(turnID: turn.id, activityID: activity.id)
				} else {
					index[activity.id] = .activity(turnID: turn.id, spanID: span.id, activityID: activity.id)
				}
			}
		}
		if let summary = turn.summary,
			blocks.contains(where: { $0.rows.contains(where: { $0.id == summary.middleSummaryItemID }) }) {
			index[summary.middleSummaryItemID] = .summary(turnID: turn.id)
		}
	}

	private func registerBlockAnchors(
		for turn: AgentTranscriptTurn,
		blocks: [AgentTranscriptRenderBlock],
		into index: inout [AgentTranscriptAnchor: String]
	) {
		for block in blocks {
			if let primaryAnchor = block.primaryAnchor {
				index[primaryAnchor] = block.id
			}
			guard let spanID = block.spanID else { continue }
			if block.kind == .groupedHistory {
				index[groupedHistoryAnchor(for: turn.id, spanID: spanID)] = block.id
			}
			for activityID in block.activityIDs {
				index[semanticAnchor(for: activityID, in: turn, spanID: spanID)] = block.id
			}
		}

		switch turn.retentionTier {
		case .full:
			return
		case .condensed, .summary:
			let groupedHistoryBlockIDBySpan: [UUID: String] = Dictionary(
				uniqueKeysWithValues: blocks.compactMap { block -> (UUID, String)? in
					guard block.kind == .groupedHistory, let spanID = block.spanID else { return nil }
					return (spanID, block.id)
				}
			)
			let firstGroupedHistoryBlockID = blocks.first(where: { $0.kind == .groupedHistory })?.id
			let conclusionBlockID = blocks.first(where: { $0.kind == .conclusion })?.id
			let requestBlockID = blocks.first(where: { $0.kind == .request })?.id
			let fallbackBlockID = firstGroupedHistoryBlockID ?? conclusionBlockID ?? requestBlockID
			guard let fallbackBlockID else { return }

			if let firstGroupedHistoryBlockID {
				index[summaryAnchor(for: turn.id)] = firstGroupedHistoryBlockID
			}

			for span in turn.responseSpans {
				let spanBlockID = groupedHistoryBlockIDBySpan[span.id] ?? fallbackBlockID
				index[groupedHistoryAnchor(for: turn.id, spanID: span.id)] = spanBlockID
				for activity in span.activities {
					guard !isSuppressedActivity(activity) else { continue }
					if activity.id == turn.conclusionActivityID {
						index[conclusionAnchor(for: activity.id, turnID: turn.id)] = conclusionBlockID ?? spanBlockID
					} else {
						index[semanticAnchor(for: activity.id, in: turn, spanID: span.id)] = spanBlockID
					}
				}
			}
		case .archived:
			let summaryBlockID = blocks.first(where: { $0.kind == .middleSummary })?.id
			let conclusionBlockID = blocks.first(where: { $0.kind == .conclusion })?.id
			let requestBlockID = blocks.first(where: { $0.kind == .request })?.id
			let fallbackBlockID = summaryBlockID ?? conclusionBlockID ?? requestBlockID
			guard let fallbackBlockID else { return }

			for span in turn.responseSpans {
				for activity in span.activities {
					guard !isSuppressedActivity(activity) else { continue }
					if activity.id == turn.conclusionActivityID {
						index[conclusionAnchor(for: activity.id, turnID: turn.id)] = conclusionBlockID ?? fallbackBlockID
					} else {
						index[semanticAnchor(for: activity.id, in: turn, spanID: span.id)] = summaryBlockID ?? fallbackBlockID
					}
				}
			}
		}
	}
}
