import Foundation
import AgentRuntimeKit
import AgentTranscriptAssembly

/// Caller-owned export policy. The host supplies projection/materialization and
/// tool visibility; no storage, app settings, or UI state is read implicitly.
/// Text preserves the historical unescaped XML-like transcript format.
public struct AgentTranscriptExportService {
    private let suppressRow: (AgentChatItem) -> Bool
    private let visibleToolName: (String?) -> String?
    private let diagnostics: (String) -> Void

    public init(suppressRow: @escaping (AgentChatItem) -> Bool,
                visibleToolName: @escaping (String?) -> String?,
                diagnostics: @escaping (String) -> Void = { _ in }) {
        self.suppressRow = suppressRow; self.visibleToolName = visibleToolName
        self.diagnostics = diagnostics
    }

	/// Drop-priority tiers for fork transcript items (higher number = dropped first).
	private enum ForkItemDropPriority: Int, Comparable {
		/// User messages and conclusion assistant messages (last assistant per turn).
		case essential = 0
		/// System summaries and error messages.
		case context = 1
		/// Non-conclusion assistant messages (intermediate narration that survived earlier filtering).
		case supplemental = 2
		/// Tool call previews — lowest priority, dropped first.
		case toolCall = 3

		static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
	}

	private struct ForkItem {
		enum Payload {
			case tagged(tag: String, text: String)
			case rawXML(String)
		}
		let pos: Int
		let payload: Payload
		let dropPriority: ForkItemDropPriority
		let turnID: UUID?
	}

    /// Entries must already be materialized and filtered for the requested cutoff.
    public func forkXML(from entries: [AgentTranscriptExportEntry], maxTranscriptItems: Int = 200,
                        maxToolArgsCharacters: Int = 2_000) -> String {
		// --- Phase 1: Flatten entries into prioritized fork items ---

		// First pass: identify conclusion assistant entries (last assistant per turn).
		var lastAssistantIndexByTurn: [UUID: Int] = [:]
		var flatIndex = 0
		for entry in entries {
			for row in entry.xmlItems {
				if AgentDisplayableText.hasDisplayableBody(row.text) && (row.kind == .assistant || row.kind == .assistantInline),
					let turnID = entry.turnID {
					lastAssistantIndexByTurn[turnID] = flatIndex
				}
				flatIndex += 1
			}
		}
		let conclusionIndices = Set(lastAssistantIndexByTurn.values)

		// Second pass: build fork items with priorities.
		var forkItems: [ForkItem] = []
		flatIndex = 0
		var pos = 0
		for entry in entries {
			let tid = entry.turnID
			for row in entry.xmlItems {
				defer { flatIndex += 1 }
				switch row.kind {
				case .user:
					forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "user", text: row.text), dropPriority: .essential, turnID: tid))
					pos += 1
				case .assistant, .assistantInline:
					guard AgentDisplayableText.hasDisplayableBody(row.text) && (row.kind == .assistant || row.kind == .assistantInline) else { continue }
					let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
					let isConclusion = conclusionIndices.contains(flatIndex)
					forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "assistant", text: trimmed), dropPriority: isConclusion ? .essential : .supplemental, turnID: tid))
					pos += 1
				case .system:
					let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !trimmed.isEmpty else { continue }
					forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "system", text: trimmed), dropPriority: .context, turnID: tid))
					pos += 1
				case .error:
					let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
					guard !trimmed.isEmpty else { continue }
					forkItems.append(ForkItem(pos: pos, payload: .tagged(tag: "error", text: trimmed), dropPriority: .context, turnID: tid))
					pos += 1
				case .toolCall:
					guard !suppressRow(row),
						let toolName = visibleToolName(row.toolName) else { continue }
					let args = Self.truncateArgs(row.toolArgsJSON, max: maxToolArgsCharacters)
					let xml = args.isEmpty
						? "<tool_call name=\"\(toolName)\"/>"
						: "<tool_call name=\"\(toolName)\">\(args)</tool_call>"
					forkItems.append(ForkItem(pos: pos, payload: .rawXML(xml), dropPriority: .toolCall, turnID: tid))
					pos += 1
				case .toolResult, .thinking:
					break
				}
			}
		}

		// --- Phase 2: Fit within budget by dropping lowest-importance items first ---
		//
		// Non-essential tiers (toolCall, supplemental, context) are dropped individually,
		// oldest first. Essential items are dropped in turn-groups so a user prompt is
		// never orphaned from its conclusion assistant (or vice versa).
		func renderedOutputCount(excluding dropIndices: Set<Int>) -> Int {
			var count = 0
			var lastWasSystem = false
			for (index, item) in forkItems.enumerated() where !dropIndices.contains(index) {
				switch item.payload {
				case let .tagged(tag, _):
					if tag == "system", lastWasSystem {
						continue
					}
					count += 1
					lastWasSystem = (tag == "system")
				case .rawXML:
					count += 1
					lastWasSystem = false
				}
			}
			return count
		}

		var surviving = forkItems
		var droppedCount = 0
		let initialRenderedCount = renderedOutputCount(excluding: [])
		var survivingRenderedCount = initialRenderedCount
		if initialRenderedCount > maxTranscriptItems {
			// Step 1: Drop non-essential items oldest-first by tier.
			let nonEssentialSorted = forkItems.indices
				.filter { forkItems[$0].dropPriority != .essential }
				.sorted { a, b in
					if forkItems[a].dropPriority != forkItems[b].dropPriority {
						return forkItems[a].dropPriority > forkItems[b].dropPriority
					}
					return a < b
				}
			var dropIndices = Set<Int>()
			var currentRendered = initialRenderedCount
			for idx in nonEssentialSorted {
				dropIndices.insert(idx)
				currentRendered = renderedOutputCount(excluding: dropIndices)
				if currentRendered <= maxTranscriptItems { break }
			}

			// Step 2: If still over budget, drop essential items in whole-turn groups
			// (oldest turns first) so user+conclusion pairs stay together.
			if currentRendered > maxTranscriptItems {
				// Group essential indices by turnID, ordered by first appearance.
				var turnOrder: [UUID] = []
				var essentialByTurn: [UUID: [Int]] = [:]
				for idx in forkItems.indices where forkItems[idx].dropPriority == .essential {
					guard let turnID = forkItems[idx].turnID else { continue }
					if essentialByTurn[turnID] == nil { turnOrder.append(turnID) }
					essentialByTurn[turnID, default: []].append(idx)
				}
				for turnID in turnOrder {
					guard currentRendered > maxTranscriptItems else { break }
					for idx in essentialByTurn[turnID, default: []] {
						dropIndices.insert(idx)
					}
					currentRendered = renderedOutputCount(excluding: dropIndices)
				}
			}

			droppedCount = dropIndices.count
			survivingRenderedCount = currentRendered
			surviving = forkItems.enumerated().compactMap { i, item in
				dropIndices.contains(i) ? nil : item
			}
		}

		diagnostics("buildForkTranscriptXML items=\(forkItems.count) rendered=\(initialRenderedCount) surviving=\(surviving.count) survivingRendered=\(survivingRenderedCount) dropped=\(droppedCount)")

		// --- Phase 3: Render survivors in chronological order ---
		enum ForkTranscriptOutput {
			case tagged(tag: String, text: String)
			case rawXML(String)
		}
		var outputs: [ForkTranscriptOutput] = []
		func appendOutput(_ output: ForkTranscriptOutput) {
			switch output {
			case let .tagged(tag, text):
				if tag == "system",
					case let .tagged(lastTag, lastText)? = outputs.last,
					lastTag == "system" {
					outputs[outputs.count - 1] = .tagged(tag: "system", text: lastText + "\n" + text)
				} else {
					outputs.append(.tagged(tag: tag, text: text))
				}
			case .rawXML:
				outputs.append(output)
			}
		}

		for item in surviving {
			switch item.payload {
			case let .tagged(tag, text):
				appendOutput(.tagged(tag: tag, text: text))
			case let .rawXML(xml):
				appendOutput(.rawXML(xml))
			}
		}

		var lines: [String] = ["<transcript>"]
		for output in outputs {
			switch output {
			case let .tagged(tag, text):
				lines.append("<\(tag)>\(text)</\(tag)>")
			case let .rawXML(xml):
				lines.append(xml)
			}
		}
		if droppedCount > 0 {
			lines.append("<note>\(droppedCount) item\(droppedCount == 1 ? "" : "s") omitted to fit \(maxTranscriptItems) item budget.</note>")
		}
		lines.append("</transcript>")
		return lines.joined(separator: "\n")
	}


	public func filteredEntries(
		_ entries: [AgentTranscriptExportEntry],
		preserveIntermediateAssistantNarration: Bool = false
	) -> [AgentTranscriptExportEntry] {
		// Pass 1: Drop summary-only tool results and diagnostic errors
		let itemFiltered = entries.filter { entry in
			guard let item = entry.xmlItems.first else { return true }
			// Drop [ede_diagnostic] error items
			if item.kind == .error,
				item.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[ede_diagnostic]") {
				return false
			}
			// Drop summary-only tool results
			if item.kind == .toolResult, isSummaryOnlyToolResult(item) {
				return false
			}
			return true
		}
		// Pass 2: Filter intermediate assistant narration per turn for compact handoff.
		guard !preserveIntermediateAssistantNarration else { return itemFiltered }
		return filterIntermediateAssistantNarration(itemFiltered)
	}

	private func isSummaryOnlyToolResult(_ item: AgentChatItem) -> Bool {
		guard item.kind == .toolResult else { return false }
		guard let json = item.toolResultJSON ?? (item.text.isEmpty ? nil : item.text) else { return false }
		return json.contains("\"summary_only\":true") || json.contains("\"summary_only\": true")
	}

	/// Filters intermediate assistant narration within each turn.
	///
	/// Within a turn's sequence, assistant messages are classified by position relative
	/// to tool call boundaries:
	/// - First assistant (before any tools): kept (sets intent)
	/// - Intermediate (tools before, not the last assistant): dropped
	/// - Last intermediate: truncated (~1 line)
	/// - Last assistant in turn: kept in full (conclusion)
	public func filterIntermediateAssistantNarration(_ entries: [AgentTranscriptExportEntry]) -> [AgentTranscriptExportEntry] {
		// Group entry indices by turnID
		var turnSegments: [[Int]] = []
		var currentTurnID: UUID?
		var currentSegment: [Int] = []
		for (index, entry) in entries.enumerated() {
			if entry.turnID != currentTurnID {
				if !currentSegment.isEmpty {
					turnSegments.append(currentSegment)
				}
				currentTurnID = entry.turnID
				currentSegment = [index]
			} else {
				currentSegment.append(index)
			}
		}
		if !currentSegment.isEmpty {
			turnSegments.append(currentSegment)
		}

		var dropIndices = Set<Int>()
		var truncateIndices = Set<Int>()

		for segment in turnSegments {
			// Identify assistant and tool-call positions within this turn
			var assistantIndices: [Int] = []
			var toolBeforeSeen = false
			var hasToolBefore = Set<Int>()

			for i in segment {
				let entry = entries[i]
				if isDisplayableAssistantEntry(entry) {
					assistantIndices.append(i)
					if toolBeforeSeen { hasToolBefore.insert(i) }
				} else if entry.isToolBoundary {
					toolBeforeSeen = true
				}
			}

			// Intermediate = has tool before AND is not the last assistant in the turn.
			// The last assistant is always the conclusion (kept in full).
			guard let lastAssistant = assistantIndices.last else { continue }
			let intermediates = assistantIndices.filter {
				hasToolBefore.contains($0) && $0 != lastAssistant
			}
			guard !intermediates.isEmpty else { continue }

			// Last intermediate gets truncated; all others are dropped
			for (offset, idx) in intermediates.enumerated() {
				if offset == intermediates.count - 1 {
					truncateIndices.insert(idx)
				} else {
					dropIndices.insert(idx)
				}
			}
		}

		guard !dropIndices.isEmpty || !truncateIndices.isEmpty else { return entries }

		diagnostics("filterIntermediateAssistant dropped=\(dropIndices.count) truncated=\(truncateIndices.count)")
		return entries.enumerated().compactMap { index, entry in
			if dropIndices.contains(index) { return nil }
			if truncateIndices.contains(index) {
				return truncateAssistantEntry(entry)
			}
			return entry
		}
	}

    private func isDisplayableAssistantEntry(_ entry: AgentTranscriptExportEntry) -> Bool {
        guard let item = entry.xmlItems.first else { return false }
        return (item.kind == .assistant || item.kind == .assistantInline) && AgentDisplayableText.hasDisplayableBody(item.text)
    }

	private func truncateAssistantEntry(_ entry: AgentTranscriptExportEntry) -> AgentTranscriptExportEntry {
		let truncatedItems = entry.xmlItems.map { item -> AgentChatItem in
			guard item.kind == .assistant || item.kind == .assistantInline else { return item }
			var copy = item
			copy.text = Self.compactConclusionText(from: item.text) ?? ""
			return copy
		}
		var truncatedMigrated = entry.migratedItem
		if let mi = entry.migratedItem,
			mi.kind == .assistant || mi.kind == .assistantInline {
			truncatedMigrated = mi
			truncatedMigrated?.text = Self.compactConclusionText(from: mi.text) ?? ""
		}
		return AgentTranscriptExportEntry(
			migratedItem: truncatedMigrated,
			sourceRowID: entry.sourceRowID,
			xmlItems: truncatedItems,
			turnID: entry.turnID,
			isToolBoundary: entry.isToolBoundary
		)
	}

	public static func compactConclusionText(from text: String?) -> String? {
		guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
		if text.count <= 220 {
			return text
		}
		let endIndex = text.index(text.startIndex, offsetBy: 220)
		return String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
	}

	private static func truncateArgs(_ rawArgs: String?, max limit: Int) -> String {
		guard let rawArgs, !rawArgs.isEmpty else { return "" }
		return rawArgs.count > limit ? String(rawArgs.prefix(limit)) + "…" : rawArgs
	}
	public static func turnsForExport(
		from transcript: AgentTranscript,
		upToRowID: UUID?
	) -> [AgentTranscriptTurn] {
		guard let upToRowID else { return transcript.turns }
		// Find the turn that contains the target row and include it and all prior turns.
		// Check activity IDs, request IDs, and compacted summary IDs so we don't miss
		// synthetic rows from already-compacted turns.
		for (index, turn) in transcript.turns.enumerated() {
			var rowIDs = turn.allActivities.map(\.id)
			if let requestID = turn.request?.id {
				rowIDs.append(requestID)
			}
			if let summaryItemID = turn.summary?.middleSummaryItemID {
				rowIDs.append(summaryItemID)
			}
			if turn.conclusionActivityID == nil, turn.summary != nil {
				rowIDs.append(AgentTranscriptIdentity.conclusionID(for: turn.id))
			}
			if rowIDs.contains(upToRowID) {
				return Array(transcript.turns.prefix(through: index))
			}
		}
		// Row not found — fall back to full transcript.
		return transcript.turns
	}

    /// Renumbers migrated rows without touching their identities, timestamps, or tool completion state.
    public static func migratedItems(from entries: [AgentTranscriptExportEntry]) -> [AgentChatItem] {
        entries.compactMap(\.migratedItem).enumerated().map { index, item in
            var copy = item
            copy.isStreaming = false
            copy.sequenceIndex = index
            return copy
        }
    }
}
