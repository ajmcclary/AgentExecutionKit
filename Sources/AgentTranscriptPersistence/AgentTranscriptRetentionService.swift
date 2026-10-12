import Foundation
import AgentRuntimeKit

public struct AgentTranscriptRetentionService {
	private let services: AgentTranscriptRetentionServices
	public init(services: AgentTranscriptRetentionServices) { self.services = services }
	public static let targetWorkingUnitCount = 55
	public static let softMaxWorkingUnitCount = 65
	public static let hardMaxWorkingUnitCount = 70
	/// Storage-retention invariant: preserve full detail for the transcript suffix anchored
	/// at the earliest of the last visible tool executions. This is intentionally separate
	/// from projection's visual detailed-tool budget even though both are currently 8.
	public static let protectedDetailedToolExecutionTailCount = 8

	private struct ProtectedToolTailRegion {
		let protectedTurnIDs: Set<UUID>
	}

	private struct CompactionPressure {
		let workingUnitCount: Int

		var exceedsSoftLimit: Bool {
			workingUnitCount > AgentTranscriptRetentionService.softMaxWorkingUnitCount
		}

		var exceedsTargetLimit: Bool {
			workingUnitCount > AgentTranscriptRetentionService.targetWorkingUnitCount
		}

		var exceedsHardLimit: Bool {
			workingUnitCount > AgentTranscriptRetentionService.hardMaxWorkingUnitCount
		}

		init(workingUnitCount: Int) {
			self.workingUnitCount = workingUnitCount
		}


		func removingWorkingUnits(_ count: Int) -> CompactionPressure {
			CompactionPressure(workingUnitCount: max(0, workingUnitCount - max(0, count)))
		}
	}

	public func compact(
		_ transcript: AgentTranscript,
		mode: AgentTranscriptCompactionMode = .recomputeAll,
		protectedTurnID: UUID? = nil
	) -> AgentTranscript {
		switch mode {
		case .recomputeAll:
			return AgentTranscriptDurableFrontierSupport.normalizedTranscript(
				recomputedCompaction(
					transcript,
					mode: mode,
					protectedTurnID: protectedTurnID
				)
			)
		case .preserveDurableFrontier:
			guard let frozenPrefixTurnCount = AgentTranscriptDurableFrontierSupport.validatedFrozenPrefixTurnCountForIncrementalReuse(
				in: transcript
			),
				frozenPrefixTurnCount > 0
			else {
				return compact(
					transcript,
					mode: .recomputeAll,
					protectedTurnID: protectedTurnID
				)
			}
			let frozenPrefix = Array(transcript.turns.prefix(frozenPrefixTurnCount))
			// This prevention fix does not promote legacy non-full prefix turns back to `.full`.
			// When the protected tool-tail region overlaps an already-frozen prefix, reusing the
			// full frozen prefix is therefore the least destructive no-worsening behavior: it
			// preserves whatever summary/archived/recoverable legacy detail remains, while new
			// full-detail suffix turns are still protected by the recomputed compaction pass.
			let safeReusablePrefixCount = frozenPrefixTurnCount
			var compacted = recomputedCompaction(
				transcript,
				mode: mode,
				protectedTurnID: protectedTurnID
			)
			guard compacted.turns.count >= frozenPrefixTurnCount else {
				return AgentTranscriptDurableFrontierSupport.normalizedTranscript(compacted)
			}
			if safeReusablePrefixCount > 0 {
				compacted.turns.replaceSubrange(0..<safeReusablePrefixCount, with: frozenPrefix.prefix(safeReusablePrefixCount))
			}
			return AgentTranscriptDurableFrontierSupport.normalizedTranscript(compacted)
		}
	}

	private func recomputedCompaction(
		_ transcript: AgentTranscript,
		mode: AgentTranscriptCompactionMode,
		protectedTurnID: UUID?
	) -> AgentTranscript {
		#if DEBUG
		let startedAt = services.clock()
		var downshiftIterationCount = 0
		var archiveIterationCount = 0
		var archivedTurnCount = 0
		#endif
		var copy = transcript
		var pressure = CompactionPressure(workingUnitCount: services.workingUnits(copy))
		#if DEBUG
		let initialWorkingUnitCount = pressure.workingUnitCount
		#endif
		guard pressure.exceedsSoftLimit else {
			let trimmed = structurallyTrimmedTranscript(copy)
			#if DEBUG
			if services.diagnosticsEnabled() {
				services.observeCompaction(.init(
					mode: mode,
					initialWorkingUnitCount: initialWorkingUnitCount,
					finalWorkingUnitCount: CompactionPressure(workingUnitCount: services.workingUnits(trimmed)).workingUnitCount,
					softGuardSkippedScan: true,
					downshiftIterationCount: 0,
					archiveIterationCount: 0,
					archivedTurnCount: 0,
					protectedToolTailTurnCount: 0,
					durationMS: max(0, (services.clock() - startedAt) * 1000)
				))
			}
			#endif
			return trimmed
		}
		let protectedToolTailTurnIDs = protectedToolTailRegion(in: copy).protectedTurnIDs
		while pressure.exceedsTargetLimit {
			if applyOldestTierDownshiftIfPossible(
				to: &copy,
				protectedTurnID: protectedTurnID,
				protectedToolTailTurnIDs: protectedToolTailTurnIDs
			) {
				#if DEBUG
				downshiftIterationCount += 1
				#endif
				pressure = CompactionPressure(workingUnitCount: services.workingUnits(copy))
				continue
			}
			guard pressure.exceedsHardLimit else {
				break
			}
			let archivedThisPass = archiveOldestEligibleSummariesIfNeeded(
				in: &copy,
				pressure: &pressure,
				protectedTurnID: protectedTurnID,
				protectedToolTailTurnIDs: protectedToolTailTurnIDs
			)
			guard archivedThisPass > 0 else {
				break
			}
			#if DEBUG
			archiveIterationCount += 1
			archivedTurnCount += archivedThisPass
			#endif
		}
		let trimmed = structurallyTrimmedTranscript(copy)
		#if DEBUG
		if services.diagnosticsEnabled() {
			services.observeCompaction(.init(
				mode: mode,
				initialWorkingUnitCount: initialWorkingUnitCount,
				finalWorkingUnitCount: CompactionPressure(workingUnitCount: services.workingUnits(trimmed)).workingUnitCount,
				softGuardSkippedScan: false,
				downshiftIterationCount: downshiftIterationCount,
				archiveIterationCount: archiveIterationCount,
				archivedTurnCount: archivedTurnCount,
				protectedToolTailTurnCount: protectedToolTailTurnIDs.count,
				durationMS: max(0, (services.clock() - startedAt) * 1000)
			))
		}
		#endif
		return trimmed
	}


	public func estimatedWorkingUnitCount(for transcript: AgentTranscript) -> Int {
		services.workingUnits(transcript)
	}

	private func applyOldestTierDownshiftIfPossible(
		to transcript: inout AgentTranscript,
		protectedTurnID: UUID?,
		protectedToolTailTurnIDs: Set<UUID>
	) -> Bool {
		guard let index = oldestTierDownshiftableTurnIndex(
			in: transcript.turns,
			protectedTurnID: protectedTurnID,
			protectedToolTailTurnIDs: protectedToolTailTurnIDs
		) else {
			return false
		}
		switch transcript.turns[index].retentionTier {
		case .full:
			transcript.turns[index].retentionTier = .condensed
		case .condensed:
			transcript.turns[index].retentionTier = .summary
		case .summary, .archived:
			return false
		}
		return true
	}

	private func archiveOldestEligibleSummariesIfNeeded(
		in transcript: inout AgentTranscript,
		pressure: inout CompactionPressure,
		protectedTurnID: UUID?,
		protectedToolTailTurnIDs: Set<UUID>
	) -> Int {
		guard pressure.exceedsHardLimit, !transcript.turns.isEmpty else { return 0 }
		let lastTurnIndex = transcript.turns.count - 1
		var indicesToArchive: [Int] = []
		var releasedWorkingUnits = 0

		for index in transcript.turns.indices {
			let turn = transcript.turns[index]
			guard isArchivableSummaryTurn(
				turn,
				at: index,
				lastTurnIndex: lastTurnIndex,
				protectedTurnID: protectedTurnID,
				protectedToolTailTurnIDs: protectedToolTailTurnIDs
			) else {
				continue
			}
			indicesToArchive.append(index)
			releasedWorkingUnits += services.summaryWorkingUnits(turn)
			if pressure.workingUnitCount - releasedWorkingUnits <= Self.hardMaxWorkingUnitCount {
				break
			}
		}

		guard !indicesToArchive.isEmpty else { return 0 }
		for index in indicesToArchive {
			transcript.turns[index].retentionTier = .archived
		}
		pressure = pressure.removingWorkingUnits(releasedWorkingUnits)
		return indicesToArchive.count
	}

	public func retainedFullDetailBytes(for transcript: AgentTranscript) -> Int {
		transcript.turns.reduce(into: 0) { partial, turn in
			guard turn.retentionTier == .full else { return }
			partial += retainedDetailBytes(for: turn)
		}
	}

	private func retainedDetailBytes(for turn: AgentTranscriptTurn) -> Int {
		turn.allActivities.reduce(into: 0) { partial, activity in
			partial += activity.text.lengthOfBytes(using: .utf8)
			partial += (activity.reasoning ?? "").lengthOfBytes(using: .utf8)
			guard let execution = activity.toolExecution else { return }
			partial += (execution.argsJSON ?? "").lengthOfBytes(using: .utf8)
			let resultJSON = execution.resultJSON ?? ""
			let resultBytes = resultJSON.lengthOfBytes(using: .utf8)
			if resultJSON != activity.text {
				partial += resultBytes
			}
			partial += (execution.summaryText ?? "").lengthOfBytes(using: .utf8)
		}
	}

	/// Returns the index of the oldest turn eligible for tier downshifting.
	/// The newest turn is always excluded — its inline activities must survive compaction.
	/// While the newest turn is active/pending, keep the latest full-detail continuation suffix
	/// intact so a restored response turn and subsequent steering/user rows do not collapse
	/// before the agent has a chance to answer.
	private func oldestTierDownshiftableTurnIndex(
		in turns: [AgentTranscriptTurn],
		protectedTurnID: UUID?,
		protectedToolTailTurnIDs: Set<UUID>
	) -> Int? {
		let lastTurnIndex = turns.count - 1
		let activeContinuationProtectedTurnIDs = activeContinuationProtectedTurnIDs(in: turns)
		return turns.enumerated().first(where: { index, turn in
			index != lastTurnIndex
				&& turn.isCompleted
				&& (turn.retentionTier == .full || turn.retentionTier == .condensed)
				&& turn.id != protectedTurnID
				&& !activeContinuationProtectedTurnIDs.contains(turn.id)
				&& !protectedToolTailTurnIDs.contains(turn.id)
		})?.offset
	}

	private func activeContinuationProtectedTurnIDs(in turns: [AgentTranscriptTurn]) -> Set<UUID> {
		guard turns.count >= 2 else { return [] }
		let newestIndex = turns.count - 1
		let newest = turns[newestIndex]
		guard shouldProtectActiveContinuationSuffix(for: newest) else { return [] }

		let precedingRange = turns.indices[..<newestIndex]
		let preferredAnchorIndex = precedingRange.reversed().first { index in
			let turn = turns[index]
			return turn.retentionTier == .full
				&& turn.isCompleted
				&& turn.hasStoredActivities
		}
		let fallbackAnchorIndex = preferredAnchorIndex ?? precedingRange.reversed().first { index in
			let turn = turns[index]
			return turn.retentionTier == .full
				&& turn.isCompleted
		}
		guard let anchorIndex = fallbackAnchorIndex else { return [] }

		return Set(turns[anchorIndex..<newestIndex].compactMap { turn in
			turn.retentionTier == .full ? turn.id : nil
		})
	}

	private func shouldProtectActiveContinuationSuffix(for newest: AgentTranscriptTurn) -> Bool {
		guard newest.completedAt == nil else {
			return false
		}
		if let terminalState = newest.terminalState {
			return terminalState.isActive
		}
		if newest.responseSpans.contains(where: { $0.lifecycle == .open }) {
			return true
		}
		if newest.request != nil && newest.responseSpans.isEmpty {
			return true
		}
		return !newest.isCompleted
	}

	private func isArchivableSummaryTurn(
		_ turn: AgentTranscriptTurn,
		at index: Int,
		lastTurnIndex: Int,
		protectedTurnID: UUID?,
		protectedToolTailTurnIDs: Set<UUID>
	) -> Bool {
		index != lastTurnIndex
			&& turn.isCompleted
			&& turn.retentionTier == .summary
			&& turn.id != protectedTurnID
			&& !protectedToolTailTurnIDs.contains(turn.id)
	}

	private func protectedToolTailRegion(
		in transcript: AgentTranscript,
		limit: Int = Self.protectedDetailedToolExecutionTailCount
	) -> ProtectedToolTailRegion {
		#if DEBUG
		let startedAt = services.clock()
		var turnsVisited = 0
		var spansInspected = 0
		var activitiesInspected = 0
		var alreadyOrderedSpanCount = 0
		var sortedSpanCount = 0
		var summarizedToolSignalUseCount = 0
		var summarizedToolSignalCount = 0

		func emit(countedToolExecutionCount: Int, protectedTurnCount: Int) {
			guard services.diagnosticsEnabled() else { return }
			services.observeProtectedTail(.init(
				transcriptTurnCount: transcript.turns.count,
				limit: limit,
				turnsVisited: turnsVisited,
				spansInspected: spansInspected,
				activitiesInspected: activitiesInspected,
				alreadyOrderedSpanCount: alreadyOrderedSpanCount,
				sortedSpanCount: sortedSpanCount,
				summarizedToolSignalUseCount: summarizedToolSignalUseCount,
				summarizedToolSignalCount: summarizedToolSignalCount,
				countedToolExecutionCount: countedToolExecutionCount,
				protectedTurnCount: protectedTurnCount,
				durationMS: max(0, (services.clock() - startedAt) * 1000)
			))
		}
		#endif
		guard limit > 0, !transcript.turns.isEmpty else {
			#if DEBUG
			emit(countedToolExecutionCount: 0, protectedTurnCount: 0)
			#endif
			return ProtectedToolTailRegion(protectedTurnIDs: [])
		}

		var countedToolExecutionCount = 0
		var earliestProtectedTurnIndex: Int?

		for turnIndex in transcript.turns.indices.reversed() {
			#if DEBUG
			turnsVisited += 1
			#endif
			let turn = transcript.turns[turnIndex]
			let remaining = limit - countedToolExecutionCount
			guard remaining > 0 else { break }

			#if DEBUG
			let visibleToolSignalCount = services.diagnosticsEnabled()
				? debugVisibleToolSignalCount(
					in: turn,
					limit: remaining,
					spansInspected: &spansInspected,
					activitiesInspected: &activitiesInspected,
					alreadyOrderedSpanCount: &alreadyOrderedSpanCount,
					sortedSpanCount: &sortedSpanCount
				)
				: self.visibleToolSignalCount(in: turn, limit: remaining)
			#else
			let visibleToolSignalCount = self.visibleToolSignalCount(in: turn, limit: remaining)
			#endif
			if visibleToolSignalCount > 0 {
				countedToolExecutionCount += visibleToolSignalCount
				earliestProtectedTurnIndex = turnIndex
			} else {
				let summaryToolSignalCount = self.summarizedToolSignalCount(in: turn)
				if summaryToolSignalCount > 0 {
					#if DEBUG
					summarizedToolSignalUseCount += 1
					summarizedToolSignalCount += min(summaryToolSignalCount, remaining)
					#endif
					countedToolExecutionCount += min(summaryToolSignalCount, remaining)
					earliestProtectedTurnIndex = turnIndex
				}
			}

			if countedToolExecutionCount >= limit {
				break
			}
		}

		guard let earliestProtectedTurnIndex else {
			#if DEBUG
			emit(countedToolExecutionCount: countedToolExecutionCount, protectedTurnCount: 0)
			#endif
			return ProtectedToolTailRegion(protectedTurnIDs: [])
		}

		let protectedTurnIDs = Set(transcript.turns[earliestProtectedTurnIndex...].map(\.id))
		#if DEBUG
		emit(countedToolExecutionCount: countedToolExecutionCount, protectedTurnCount: protectedTurnIDs.count)
		#endif
		return ProtectedToolTailRegion(protectedTurnIDs: protectedTurnIDs)
	}

	#if DEBUG
	private func debugVisibleToolSignalCount(
		in turn: AgentTranscriptTurn,
		limit: Int,
		spansInspected: inout Int,
		activitiesInspected: inout Int,
		alreadyOrderedSpanCount: inout Int,
		sortedSpanCount: inout Int
	) -> Int {
		guard limit > 0 else { return 0 }
		var countedToolExecutionCount = 0
		var seenExecutionIDs: Set<String> = []
		for span in turn.responseSpans {
			spansInspected += 1
			let activities: [AgentTranscriptActivity]
			if activitiesAreInTranscriptOrder(span.activities) {
				alreadyOrderedSpanCount += 1
				activities = span.activities
			} else {
				sortedSpanCount += 1
				activities = span.activities.sorted(by: transcriptActivityPrecedes)
			}
			for activity in activities {
				activitiesInspected += 1
				guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { continue }
				guard !services.suppressActivity(activity) else { continue }
				let stableExecutionID = activity.toolExecution?.stableExecutionID ?? activity.id.uuidString
				guard seenExecutionIDs.insert(stableExecutionID).inserted else { continue }
				countedToolExecutionCount += 1
				if countedToolExecutionCount >= limit {
					return countedToolExecutionCount
				}
			}
		}
		return countedToolExecutionCount
	}
	#endif

	private func visibleToolSignalCount(in turn: AgentTranscriptTurn, limit: Int) -> Int {
		guard limit > 0 else { return 0 }
		var countedToolExecutionCount = 0
		var seenExecutionIDs: Set<String> = []
		for span in turn.responseSpans {
			for activity in transcriptOrderedActivities(in: span) {
				guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { continue }
				guard !services.suppressActivity(activity) else { continue }
				let stableExecutionID = activity.toolExecution?.stableExecutionID ?? activity.id.uuidString
				guard seenExecutionIDs.insert(stableExecutionID).inserted else { continue }
				countedToolExecutionCount += 1
				if countedToolExecutionCount >= limit {
					return countedToolExecutionCount
				}
			}
		}
		return countedToolExecutionCount
	}

	private func transcriptOrderedActivities(in span: AgentTranscriptProviderResponseSpan) -> [AgentTranscriptActivity] {
		guard !activitiesAreInTranscriptOrder(span.activities) else {
			return span.activities
		}
		return span.activities.sorted(by: transcriptActivityPrecedes)
	}

	private func activitiesAreInTranscriptOrder(_ activities: [AgentTranscriptActivity]) -> Bool {
		guard activities.count > 1 else { return true }
		for index in activities.indices.dropFirst() {
			let previousIndex = activities.index(before: index)
			if transcriptActivityPrecedes(activities[index], activities[previousIndex]) {
				return false
			}
		}
		return true
	}

	private func transcriptActivityPrecedes(_ lhs: AgentTranscriptActivity, _ rhs: AgentTranscriptActivity) -> Bool {
		if lhs.sequenceIndex == rhs.sequenceIndex {
			return lhs.timestamp < rhs.timestamp
		}
		return lhs.sequenceIndex < rhs.sequenceIndex
	}

	private func summarizedToolSignalCount(in turn: AgentTranscriptTurn) -> Int {
		let summaryToolCount = turn.summary?.toolCount ?? 0
		let collapsedToolCount = turn.responseSpans.reduce(0) { partial, span in
			partial + (span.collapsedSummary?.hiddenToolCardCount ?? 0)
		}
		return max(summaryToolCount, collapsedToolCount)
	}

	private func structurallyTrimmedTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
		var copy = transcript
		for index in copy.turns.indices {
			trimTurnForRetention(&copy.turns[index])
		}
		return copy
	}

	private func trimTurnForRetention(_ turn: inout AgentTranscriptTurn) {
		switch turn.retentionTier {
		case .full:
			turn.summary = nil
			for index in turn.responseSpans.indices {
				turn.responseSpans[index].collapsedSummary = nil
			}
		case .condensed, .summary, .archived:
			let snapshot = turn
			if turn.summary == nil {
				turn.summary = services.summarizeTurn(snapshot)
			}
			for index in turn.responseSpans.indices {
				trimSpanForRetention(&turn.responseSpans[index], in: snapshot, tier: turn.retentionTier)
			}
			if let summary = turn.summary {
				turn.summary = normalizeSummaryForRetention(summary, tier: turn.retentionTier)
			}
		}
	}

	private func trimSpanForRetention(
		_ span: inout AgentTranscriptProviderResponseSpan,
		in turn: AgentTranscriptTurn,
		tier: AgentTranscriptRetentionTier
	) {
		if span.lastActivityAt == nil {
			span.lastActivityAt = span.activities.last?.timestamp
		}
		if span.completedAt == nil, span.lifecycle != .open {
			span.completedAt = span.lastActivityAt ?? span.startedAt
		}
		switch tier {
		case .full:
			span.collapsedSummary = nil
			if !turn.isCompleted || span.lifecycle == .open {
				span.fullRenderGroupedHistoryCache = nil
			}
		case .condensed, .summary:
			span.fullRenderGroupedHistoryCache = nil
			if span.collapsedSummary == nil {
				span.collapsedSummary = services.summarizeSpan(span, turn)
			}
			let conclusionID = turn.conclusionActivityID
			span.activities = span.activities.filter { $0.id == conclusionID }
		case .archived:
			span.fullRenderGroupedHistoryCache = nil
			span.collapsedSummary = nil
			let conclusionID = turn.conclusionActivityID
			span.activities = span.activities.filter { $0.id == conclusionID }
		}
	}

	private func normalizeSummaryForRetention(
		_ summary: AgentTranscriptTurnSummary,
		tier: AgentTranscriptRetentionTier
	) -> AgentTranscriptTurnSummary {
		var normalized = summary
		normalized.requestText = nil
		if normalized.compactConclusionText == nil {
			normalized.compactConclusionText = services.compactConclusion(normalized.conclusionText)
		}
		switch tier {
		case .full:
			break
		case .condensed:
			break
		case .summary, .archived:
			normalized.conclusionText = nil
		}
		return normalized
	}
}
