import Foundation
import AgentRuntimeKit

/// Caller-owned transcript sanitation; host ports supply concrete tool meaning.
public struct AgentToolPersistenceService {
    private let services: AgentToolPersistenceServices
    public init(services: AgentToolPersistenceServices) { self.services = services }
	public func sanitizeTranscriptWithMetrics(
		_ transcript: AgentTranscript,
		previousSanitizedTranscript: AgentTranscript? = nil,
		reusablePrefixTurnCount: Int? = nil,
		preservedVisibleToolResultRowIDs: Set<UUID>? = nil,
		purpose: AgentToolResultSanitizationPurpose = .runtimePresentation
	) -> AgentSanitizedTranscriptMetrics {
		let reusedTurnCount: Int = {
			switch purpose {
			case .runtimePresentation:
				return validatedReusablePrefixTurnCount(
					in: transcript,
					previousSanitizedTranscript: previousSanitizedTranscript,
					requestedPrefixTurnCount: reusablePrefixTurnCount
				)
			case .persistentStorage:
				return 0
			}
		}()
		let containsSanitizableActivities: Bool = {
			switch purpose {
			case .runtimePresentation:
				return containsToolResultActivities(in: transcript)
			case .persistentStorage:
				return containsToolExecutionActivities(in: transcript)
			}
		}()
		guard containsSanitizableActivities else {
			return AgentSanitizedTranscriptMetrics(
				transcript: transcript,
				sanitizedActivityCount: 0,
				reusedTurnCount: reusedTurnCount
			)
		}
		let preservedRowIDs: Set<UUID> = {
			switch purpose {
			case .runtimePresentation:
				// Runtime projections re-apply visible raw payloads from the ephemeral
				// payload map after sanitization. Keep the canonical transcript/source
				// suffix sanitized so persistence and derived-state reuse stay aligned.
				return preservedVisibleToolResultRowIDs ?? []
			case .persistentStorage:
				return []
			}
		}()
		var sanitizedTranscript = transcript
		if reusedTurnCount > 0, let previousSanitizedTranscript {
			sanitizedTranscript.turns.replaceSubrange(
				0..<reusedTurnCount,
				with: previousSanitizedTranscript.turns.prefix(reusedTurnCount)
			)
		}
		var sanitizedActivityCount = 0
		for turnIndex in sanitizedTranscript.turns.indices where turnIndex >= reusedTurnCount {
			sanitizedActivityCount += sanitizeTurn(
				&sanitizedTranscript.turns[turnIndex],
				preservedVisibleToolResultRowIDs: preservedRowIDs,
				purpose: purpose
			)
		}
		return AgentSanitizedTranscriptMetrics(
			transcript: sanitizedTranscript,
			sanitizedActivityCount: sanitizedActivityCount,
			reusedTurnCount: reusedTurnCount
		)
	}

	private func validatedReusablePrefixTurnCount(
		in transcript: AgentTranscript,
		previousSanitizedTranscript: AgentTranscript?,
		requestedPrefixTurnCount: Int?
	) -> Int {
		guard let previousSanitizedTranscript else { return 0 }
		let availablePrefixTurnCount = min(transcript.turns.count, previousSanitizedTranscript.turns.count)
		guard availablePrefixTurnCount > 0 else { return 0 }
		let candidatePrefixTurnCount = min(requestedPrefixTurnCount ?? availablePrefixTurnCount, availablePrefixTurnCount)
		guard candidatePrefixTurnCount > 0 else { return 0 }
		var reusableTurnCount = 0
		for index in 0..<candidatePrefixTurnCount {
			let currentTurn = transcript.turns[index]
			let previousTurn = previousSanitizedTranscript.turns[index]
			guard currentTurn.retentionTier != .full,
				previousTurn.retentionTier != .full,
				currentTurn == previousTurn
			else {
				break
			}
			reusableTurnCount += 1
		}
		return reusableTurnCount
	}

	private func containsToolResultActivities(in transcript: AgentTranscript) -> Bool {
		for turn in transcript.turns {
			for span in turn.responseSpans {
				if span.activities.contains(where: { $0.itemKind == .toolResult }) {
					return true
				}
			}
		}
		return false
	}

	private func containsToolExecutionActivities(in transcript: AgentTranscript) -> Bool {
		for turn in transcript.turns {
			for span in turn.responseSpans {
				if span.activities.contains(where: { $0.toolExecution != nil || $0.itemKind == .toolCall || $0.itemKind == .toolResult }) {
					return true
				}
			}
		}
		return false
	}

	@discardableResult
	private func sanitizeTurn(
		_ turn: inout AgentTranscriptTurn,
		preservedVisibleToolResultRowIDs: Set<UUID>,
		purpose: AgentToolResultSanitizationPurpose
	) -> Int {
		var sanitizedActivityCount = 0
		for spanIndex in turn.responseSpans.indices {
			var spanDidMutate = false
			for activityIndex in turn.responseSpans[spanIndex].activities.indices {
				var activity = turn.responseSpans[spanIndex].activities[activityIndex]
				let didNormalizeToolIdentity = normalizeToolIdentity(&activity)
				let didSanitize: Bool
				switch purpose {
				case .runtimePresentation:
					didSanitize = sanitizeRuntimeActivity(
						&activity,
						preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs
					)
				case .persistentStorage:
					didSanitize = sanitizePersistentStorageActivity(&activity)
				}
				guard didNormalizeToolIdentity || didSanitize else { continue }
				turn.responseSpans[spanIndex].activities[activityIndex] = activity
				spanDidMutate = true
				sanitizedActivityCount += 1
			}
			if spanDidMutate {
				turn.responseSpans[spanIndex].fullRenderGroupedHistoryCache = nil
			}
		}
		return sanitizedActivityCount
	}

	private func normalizeToolIdentity(
		_ activity: inout AgentTranscriptActivity
	) -> Bool {
		guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
		let originalActivity = activity
		let sourceItem = activity.toItem()
		let execution = activity.toolExecution ?? services.execution(sourceItem)
		guard var updatedExecution = execution else { return false }
		let rawToolName = updatedExecution.toolName ?? sourceItem.toolName
		if let normalizedToolName = services.visibleName(rawToolName),
			!normalizedToolName.isEmpty {
			updatedExecution.toolName = normalizedToolName
		}
		if let pathSignal = services.pathSignal(rawToolName),
			!updatedExecution.keyPaths.contains(pathSignal) {
			updatedExecution.keyPaths.insert(pathSignal, at: 0)
		}
		activity.toolExecution = updatedExecution
		services.storeExecution(updatedExecution, activity.id)
		return activity != originalActivity
	}

	private func sanitizeRuntimeActivity(
		_ activity: inout AgentTranscriptActivity,
		preservedVisibleToolResultRowIDs: Set<UUID>
	) -> Bool {
		guard activity.itemKind == .toolResult else { return false }
		guard !preservedVisibleToolResultRowIDs.contains(activity.id) else { return false }
		let item = activity.toItem()
		guard let sanitized = services.runtimeSummary(item, activity.toolExecution) else { return false }
		let generatedExecution = activity.toolExecution ?? services.execution(item)
		guard var updatedExecution = generatedExecution else { return false }
		updatedExecution.resultJSON = sanitized.resultJSON
		updatedExecution.toolIsError = sanitized.toolIsError
		updatedExecution.status = sanitized.transcriptStatus
		updatedExecution.summaryOnly = sanitized.summaryOnly
		updatedExecution.processID = sanitized.processID
		updatedExecution.exitCode = sanitized.exitCode
		services.storeExecution(updatedExecution, activity.id)
		activity.text = sanitized.text
		activity.toolExecution = updatedExecution
		return true
	}

	private func sanitizePersistentStorageActivity(
		_ activity: inout AgentTranscriptActivity
	) -> Bool {
		guard activity.toolExecution != nil || activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
		let item = activity.toItem()
		let generatedExecution = activity.toolExecution ?? services.execution(item)
		guard var updatedExecution = generatedExecution else { return false }
		let originalActivity = activity
		let normalizedToolName = services.visibleName(updatedExecution.toolName ?? item.toolName)
		var persistentSummaryOnly = true

		if activity.itemKind == .toolResult,
			let persistedSummary = services.persistedSummary(item, updatedExecution, activity.text) {
			updatedExecution.resultJSON = persistedSummary.resultJSON
			updatedExecution.toolIsError = persistedSummary.toolIsError
			updatedExecution.status = persistedSummary.transcriptStatus
			updatedExecution.processID = persistedSummary.processID
			updatedExecution.exitCode = persistedSummary.exitCode
			updatedExecution.summaryText = persistedSummary.summaryText
			persistentSummaryOnly = persistedSummary.summaryOnly
			activity.text = persistedSummary.resultJSON
		} else if activity.itemKind == .toolResult {
			let presentation = services.storagePresentation(item, updatedExecution, normalizedToolName)
			updatedExecution.resultJSON = presentation.resultJSON
			updatedExecution.summaryText = presentation.summaryText
			activity.text = presentation.resultJSON
		} else {
			updatedExecution.resultJSON = nil
			updatedExecution.summaryText = services.callSummary(normalizedToolName, updatedExecution.toolName ?? item.toolName, updatedExecution.status)
			activity.text = Self.sanitizedToolCallText(toolName: updatedExecution.toolName ?? item.toolName)
		}

		updatedExecution.argsJSON = nil
		updatedExecution.summaryOnly = persistentSummaryOnly
		updatedExecution.keyPaths = []
		enforcePersistentPayloadCap(
			activity: &activity,
			execution: &updatedExecution,
			normalizedToolName: normalizedToolName
		)
		activity.toolExecution = updatedExecution
		services.storeExecution(updatedExecution, activity.id)
		return activity != originalActivity
	}

	private func enforcePersistentPayloadCap(
		activity: inout AgentTranscriptActivity,
		execution: inout AgentTranscriptToolExecution,
		normalizedToolName: String?
	) {
		execution.processID = Self.storageSafeMetadataString(execution.processID)
		execution.summaryText = Self.smallStorageSummaryText(execution.summaryText)
		if exceedsCommittedMetadataLimit(execution.toolName) {
			execution.toolName = Self.storageSafeMetadataString(normalizedToolName) ?? "tool"
		}

		let fallbackWithMetadata = services.fallbackJSON(execution.status, normalizedToolName, execution.processID, execution.exitCode, execution.summaryText)
		let fallbackJSON = exceedsPersistedToolSummaryBudget(fallbackWithMetadata)
			? services.fallbackJSON(execution.status, normalizedToolName, nil, nil, nil)
			: fallbackWithMetadata

		if exceedsPersistedToolSummaryBudget(activity.text) {
			activity.text = fallbackJSON
		}
		if let resultJSON = execution.resultJSON,
			exceedsPersistedToolSummaryBudget(resultJSON) {
			execution.resultJSON = fallbackJSON
			if activity.itemKind == .toolResult {
				activity.text = fallbackJSON
			}
		}
		if let argsJSON = execution.argsJSON,
			exceedsPersistedToolSummaryBudget(argsJSON) {
			execution.argsJSON = nil
		}
		if let summaryText = execution.summaryText,
			exceedsPersistedToolSummaryBudget(summaryText) {
			execution.summaryText = Self.smallStorageSummaryText(summaryText)
		}
	}

    public static let maxPersistedToolSummaryBytes = 2_048
    public static func storageSafeMetadataString(_ value: String?) -> String? {
        guard let value = trimmedStorageString(value) else { return nil }
        return value.utf8.count <= 512 ? value : nil
    }
    public static func smallStorageSummaryText(_ text: String?) -> String? {
        guard let text = trimmedStorageString(text) else { return nil }
        if text.count <= 240 { return text }
        let prefix = text.prefix(237).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix + "…"
    }
    private static func trimmedStorageString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private func exceedsCommittedMetadataLimit(_ value: String?) -> Bool {
        guard let value else { return false }; return value.utf8.count > 512
    }
    private func exceedsPersistedToolSummaryBudget(_ value: String) -> Bool {
        value.utf8.count > Self.maxPersistedToolSummaryBytes
    }
    public static func sanitizedToolCallText(toolName: String?) -> String {
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return "Using tool" }; return "Using tool: \(name)"
    }
    public func sanitizeItem(_ item: AgentChatItem) -> AgentChatItem {
        guard let sanitized = services.runtimeSummary(item, nil) else { return item }
        var updated = item; updated.text = sanitized.text
        updated.toolResultJSON = sanitized.resultJSON; updated.toolIsError = sanitized.toolIsError
        return updated
    }
}
