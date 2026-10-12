import Foundation
import AgentRuntimeKit

/// Caller-actor-owned turn/span assembly. Processing state is fresh for each import.
public struct AgentTranscriptAssemblyService {
    private let services: AgentTranscriptAssemblyServices
    public init(services: AgentTranscriptAssemblyServices) { self.services = services }
	public func importLegacyItems(
		_ items: [AgentChatItem],
		terminalState: AgentSessionRunState? = nil,
		nextSequenceIndex: Int? = nil
	) -> AgentTranscript {
		guard !items.isEmpty else {
			return AgentTranscript(version: 3, turns: [], nextSequenceIndex: nextSequenceIndex ?? 0)
		}
		let orderedItems = items.sorted { lhs, rhs in
			if lhs.sequenceIndex == rhs.sequenceIndex {
				return lhs.timestamp < rhs.timestamp
			}
			return lhs.sequenceIndex < rhs.sequenceIndex
		}
		var turns: [AgentTranscriptTurn] = []
		var currentTurn: AgentTranscriptTurn?
		var currentSpan: AgentTranscriptProviderResponseSpan?
		var pendingStableExecutionIDsByToolName: [String: [String]] = [:]
		let processor = services.makeToolProcessor()

		func finalizeSpan(
			_ span: inout AgentTranscriptProviderResponseSpan,
			isCompleted: Bool
		) {
			if isCompleted {
				span.lifecycle = .completed
				span.completedAt = span.completedAt ?? span.lastActivityAt ?? span.startedAt
			} else {
				span.lifecycle = .open
				span.completedAt = nil
			}
		}

		func flushCurrentTurn(isCompleted: Bool, terminalState: AgentSessionRunState?) {
			guard var turn = currentTurn else { return }
			if var span = currentSpan {
				finalizeSpan(&span, isCompleted: isCompleted)
				turn.responseSpans.append(span)
			}
			finalizeTurn(
				&turn,
				priorTurns: turns,
				terminalState: terminalState,
				isCompleted: isCompleted
			)
			if turn.request != nil || !turn.responseSpans.isEmpty {
				turns.append(turn)
			}
			currentTurn = nil
			currentSpan = nil
			pendingStableExecutionIDsByToolName.removeAll(keepingCapacity: false)
		}

		func ensureCurrentTurn(for item: AgentChatItem) {
			if currentTurn == nil {
				currentTurn = AgentTranscriptTurn(
					id: item.id,
					request: nil,
					startedAt: item.timestamp,
					lastActivityAt: item.timestamp,
					completedAt: nil
				)
			}
			if currentSpan == nil, let turnID = currentTurn?.id {
				currentSpan = AgentTranscriptProviderResponseSpan(
					id: AgentTranscriptIdentity.spanID(turnID: turnID, ordinal: currentTurn?.responseSpans.count ?? 0),
					startedAt: item.timestamp,
					lastActivityAt: item.timestamp
				)
			}
		}

		for item in orderedItems {
			if item.kind == .user {
				flushCurrentTurn(isCompleted: true, terminalState: nil)
				currentTurn = AgentTranscriptTurn(
					id: item.id,
					request: AgentTranscriptRequestAnchor(from: item),
					startedAt: item.timestamp,
					lastActivityAt: nil,
					completedAt: nil
				)
				currentSpan = AgentTranscriptProviderResponseSpan(
					id: AgentTranscriptIdentity.spanID(turnID: item.id, ordinal: 0),
					startedAt: item.timestamp
				)
				continue
			}
			ensureCurrentTurn(for: item)
			guard var span = currentSpan else { continue }
			var toolExecution = processor.execution(item)
			if var resolvedToolExecution = toolExecution {
				let normalizedToolName = processor.normalizedName(item.toolName) ?? ""
				if item.toolInvocationID == nil, !normalizedToolName.isEmpty {
					switch item.kind {
					case .toolCall:
						pendingStableExecutionIDsByToolName[normalizedToolName, default: []].append(resolvedToolExecution.stableExecutionID)
					case .toolResult:
						if var pendingIDs = pendingStableExecutionIDsByToolName[normalizedToolName], let matchedStableID = pendingIDs.popLast() {
							resolvedToolExecution.stableExecutionID = matchedStableID
							pendingStableExecutionIDsByToolName[normalizedToolName] = pendingIDs
						}
					default:
						break
					}
				}
				toolExecution = resolvedToolExecution
			}
			let activity = AgentTranscriptActivity(
				from: item,
				toolExecution: toolExecution,
				role: role(for: item),
				sealsAssistantBoundary: processor.sealsBoundary(item, toolExecution)
			)
			span.activities.append(activity)
			span.lastActivityAt = item.timestamp
			currentSpan = span
			currentTurn?.lastActivityAt = item.timestamp
		}
		let shouldCloseTrailingTurn = !(terminalState?.isActive ?? false)
		flushCurrentTurn(
			isCompleted: shouldCloseTrailingTurn,
			terminalState: terminalState
		)

		let maxSequence = orderedItems.map(\.sequenceIndex).max() ?? -1
		return AgentTranscript(
			version: 3,
			turns: turns,
			nextSequenceIndex: nextSequenceIndex ?? (maxSequence + 1)
		)
	}

	private func role(for item: AgentChatItem) -> AgentTranscriptActivityRole {
		switch item.kind {
		case .assistant, .assistantInline:
			return .assistant
		case .toolCall, .toolResult:
			return .toolExecution
		case .system:
			return .system
		case .error:
			return .error
		case .thinking:
			return .thinking
		case .user:
			return .note
		}
	}

	private func finalizeTurn(
		_ turn: inout AgentTranscriptTurn,
		priorTurns: [AgentTranscriptTurn],
		terminalState: AgentSessionRunState?,
		isCompleted: Bool
	) {
		let activities = turn.allActivities
		turn.terminalState = terminalState ?? turn.terminalState
		turn.lastActivityAt = turn.lastActivityAt ?? activities.last?.timestamp
		if isCompleted {
			turn.completedAt = turn.completedAt ?? turn.lastActivityAt ?? turn.request?.timestamp ?? turn.startedAt
		} else {
			turn.completedAt = nil
		}
		let assistantActivities = activities.filter {
			($0.itemKind == .assistant || $0.itemKind == .assistantInline)
				&& AgentDisplayableText.hasDisplayableBody($0.text)
		}
		let lastMiddleSequenceIndex = activities.last(where: {
			$0.itemKind != .assistant && $0.itemKind != .assistantInline
		})?.sequenceIndex ?? Int.min
		let trailingAssistantActivities = assistantActivities.filter { $0.sequenceIndex > lastMiddleSequenceIndex }
		turn.conclusionActivityID = trailingAssistantActivities.reversed().first(where: \.isSubstantiveAssistant)?.id
			?? trailingAssistantActivities.last?.id
		for index in turn.responseSpans.indices {
			turn.responseSpans[index].collapsedSummary = services.summarizeSpan(turn.responseSpans[index], turn)
		}
		if isCompleted, turn.retentionTier == .full {
			turn.frozenDetailedToolTailLimit = services.frozenTailLimit(turn, priorTurns)
		} else {
			turn.frozenDetailedToolTailLimit = nil
		}
		turn.summary = services.summarizeTurn(turn)
	}

}
