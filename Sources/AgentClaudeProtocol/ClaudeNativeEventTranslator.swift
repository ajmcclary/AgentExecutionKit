import Foundation
import AIClientKit
import AgentRuntimeKit
import ClaudeRuntimeKit
import ProcessStreamFraming

public struct ClaudeNativeEventTranslator: Sendable {
	public private(set) var cliSessionID: String?
	private var toolNameByToolUseID: [String: String] = [:]
	private var invocationIDByToolUseID: [String: UUID] = [:]
	private let enableDebugLogging: Bool
	private let policy: ClaudeTranslatorPolicy

	// Slice 1 two-lane state. `pendingDiagnostics`/`currentEnvelope` are transient
	// per-`translate` scratch; the assembler and stream message id persist across
	// lines within a turn and are reset at message/result boundaries.
	private var pendingDiagnostics: [ClaudeRuntimeDiagnostic] = []
	private var pendingNormalizedEvents: [ClaudeRuntimeEvent] = []
	private var currentEnvelope: ClaudeEventEnvelope?
	private var toolInputAssembler = ClaudePartialToolInputAssembler()
	private var currentStreamMessageID: String?
	/// Slice 4a: disambiguates normalized usage payloads that carry no message id.
	private var usageOrdinalCounter: Int = 0

	public init(enableDebugLogging: Bool = false, policy: ClaudeTranslatorPolicy) {
		self.enableDebugLogging = enableDebugLogging
		self.policy = policy
	}

	private func reasoningDebug(_ message: @autoclosure () -> String) {
		guard policy.reasoningEnabled else { return }
		policy.reasoningDiagnostics("[ClaudeReasoningDebug][Translator] \(message())")
	}

	private func debugSnippet(_ text: String, limit: Int = 160) -> String {
		text
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\r")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.prefix(limit)
			.description
	}

	/// Translates one NDJSON line into the two-lane `ClaudeNativeTranslationBatch`
	/// (semantic `results` + redacted `diagnostics`) over a lossless envelope.
	/// There is deliberately no `[AIStreamResult]`-only entry point in
	/// production — a results-only path could silently discard diagnostics.
	public mutating func translate(_ lineData: Data) -> ClaudeNativeTranslationBatch {
		let envelope = ClaudeEventEnvelope.decode(line: lineData)
		pendingDiagnostics = []
		pendingNormalizedEvents = []
		currentEnvelope = envelope
		defer { currentEnvelope = nil }

		guard let json = envelope.json else {
			// A non-empty, non-JSON-object line is malformed; a blank line is benign
			// noise and produces neither results nor diagnostics.
			if trimmedASCIIWhitespace(lineData) != nil {
				pendingDiagnostics.append(.malformedLine(from: envelope))
				if enableDebugLogging, let snippet = String(data: lineData.prefix(160), encoding: .utf8) {
					policy.diagnostics("[DEBUG] ClaudeSDKTranslator: Skipping non-object payload: \(snippet)")
				}
			}
			return makeBatch(envelope: envelope, results: [])
		}

		return makeBatch(envelope: envelope, results: parseMessageDictionary(json))
	}

	private mutating func makeBatch(
		envelope: ClaudeEventEnvelope,
		results: [AIStreamResult]
	) -> ClaudeNativeTranslationBatch {
		let diagnostics = pendingDiagnostics
		pendingDiagnostics = []
		let normalizedEvents = pendingNormalizedEvents
		pendingNormalizedEvents = []
		return ClaudeNativeTranslationBatch(
			envelope: envelope,
			results: results,
			diagnostics: diagnostics,
			normalizedEvents: normalizedEvents
		)
	}

	private mutating func recordUnknownEvent() {
		guard let envelope = currentEnvelope else { return }
		pendingDiagnostics.append(.unknownEvent(from: envelope))
	}

	private mutating func recordMalformedKnownEvent(_ detail: String) {
		guard let envelope = currentEnvelope else { return }
		pendingDiagnostics.append(.malformedKnownEvent(from: envelope, detail: detail))
	}

	private mutating func recordMalformedToolInput(
		messageID: String?,
		blockIndex: Int?,
		rawBuffer: String
	) {
		pendingDiagnostics.append(
			.malformedToolInput(messageID: messageID, blockIndex: blockIndex, rawBuffer: rawBuffer)
		)
	}

	private mutating func parseMessageDictionary(_ json: [String: Any]) -> [AIStreamResult] {
		if let sessionID = firstString(in: json, keys: ["session_id", "sessionId"]) {
			cliSessionID = sessionID
		}
		let type = (json["type"] as? String) ?? ""
		switch type {
		case "system":
			return parseSystemMessage(json)
		case "assistant", "message":
			return parseAssistantMessage(json)
		case "user":
			return parseUserMessage(json)
		case "stream_event":
			return parseStreamEvent(json)
		case "tool_use":
			return parseTopLevelToolUse(json)
		case "tool_result":
			return parseTopLevelToolResult(json)
		case "result":
			return parseResultMessage(json)
		case "tool_progress":
			return parseToolProgressMessage(json)
		case "auth_status":
			return parseAuthStatusMessage(json)
		case "tool_use_summary":
			return parseToolUseSummaryMessage(json)
		case "rate_limit_event":
			return parseRateLimitEventMessage(json)
		case "error":
			if let message = firstString(in: json, keys: ["error", "message"]), !message.isEmpty {
				pendingNormalizedEvents.append(.failure(.init(message: message, extra: [:])))
				return [AIStreamResult(type: "error", text: message)]
			}
			return []
		default:
			// Unknown top-level event type: preserve as a redacted diagnostic
			// instead of dropping it silently. Results lane stays empty.
			recordUnknownEvent()
			return []
		}
	}

	private mutating func parseSystemMessage(_ json: [String: Any]) -> [AIStreamResult] {
		let subtype = (json["subtype"] as? String)?.lowercased()
		if subtype == "init" {
			if let sessionID = firstString(in: json, keys: ["session_id", "sessionId"]) {
				cliSessionID = sessionID
			}
			pendingNormalizedEvents.append(.systemInit(.init(
				sessionID: cliSessionID,
				model: firstString(in: json, keys: ["model"]),
				permissionMode: firstString(in: json, keys: ["permissionMode", "permission_mode"]),
				tools: (json["tools"] as? [Any])?.compactMap { $0 as? String } ?? [],
				extra: [:]
			)))
			return [AIStreamResult(type: AIStreamResult.lifecycleType, text: "initialized")]
		}

		if subtype == "status" {
			let status = firstString(in: json, keys: ["status"])?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			var fragments: [String] = []
			if let status, !status.isEmpty, status != "null" {
				if status.caseInsensitiveCompare("compacting") == .orderedSame {
					fragments.append("Compacting context")
				} else {
					fragments.append(status)
				}
			}
			guard !fragments.isEmpty else { return [] }
			pendingNormalizedEvents.append(.status(.init(status: status, extra: [:])))
			return [AIStreamResult(type: "status", text: fragments.joined(separator: " — "))]
		}

		if subtype == "task_started" {
			let taskID = firstString(in: json, keys: ["task_id"])
			let description = firstString(in: json, keys: ["description"])
			let fragments = ["Task started", taskID, description]
				.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			// Core carries the raw ids; the "Task started" prefix and the join are
			// legacy spellings and stay in the projection.
			pendingNormalizedEvents.append(.task(.started(
				taskID: taskID, description: description, extra: [:]
			)))
			return fragments.isEmpty ? [] : [AIStreamResult(type: "system", text: fragments.joined(separator: " — "))]
		}

		if subtype == "task_notification" {
			let taskID = firstString(in: json, keys: ["task_id"])
			let status = firstString(in: json, keys: ["status"])
			let summary = firstString(in: json, keys: ["summary"])
			let fragments = ["Task update", taskID, status, summary]
				.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			pendingNormalizedEvents.append(.task(.notification(
				taskID: taskID, status: status, summary: summary, extra: [:]
			)))
			return fragments.isEmpty ? [] : [AIStreamResult(type: "system", text: fragments.joined(separator: " — "))]
		}

		if subtype == "compact_boundary" {
			let metadata = (json["compact_metadata"] as? [String: Any]) ?? [:]
			let trigger = firstString(in: metadata, keys: ["trigger"])
			let preTokens = numberToInt(metadata["pre_tokens"])
			var fragments: [String] = ["Context compacted"]
			if let trigger, !trigger.isEmpty {
				fragments.append("trigger: \(trigger)")
			}
			if let preTokens, preTokens > 0 {
				fragments.append("at ~\(preTokens) tokens")
			}
			pendingNormalizedEvents.append(.runtime(.compactBoundary(
				trigger: trigger, preTokens: preTokens, extra: [:]
			)))
			return [AIStreamResult(type: "system", text: fragments.joined(separator: " — "))]
		}

		// Claude Code lifecycle: session_state_changed (running / idle / etc.)
		if subtype == "session_state_changed" {
			let state = firstString(
				in: json,
				keys: ["session_state", "sessionState", "state", "current_state", "currentState"]
			)?
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.lowercased()
			guard let state, !state.isEmpty else { return [] }
			pendingNormalizedEvents.append(.runtime(.sessionStateChanged(state: state, extra: [:])))
			return [AIStreamResult(type: "session_state_changed", text: state)]
		}

		// Claude Code lifecycle: task_progress — used for run-state status updates, not transcript rows
		if subtype == "task_progress" {
			let fragments: [String] = ["message", "text", "summary", "description", "status"]
				.compactMap { key in
					firstString(in: json, keys: [key])?
						.trimmingCharacters(in: .whitespacesAndNewlines)
				}
				.filter { !$0.isEmpty }
			let progressTaskID = firstString(in: json, keys: ["task_id", "taskId"])
			// Emitted for BOTH shapes, including the id-only fallback: the projection
			// reproduces the "Task <id>" spelling from the same two facts.
			pendingNormalizedEvents.append(.task(.progress(
				taskID: progressTaskID, fragments: fragments, extra: [:]
			)))
			guard !fragments.isEmpty else {
				// Fall back to task_id if no descriptive text is available
				if let taskID = progressTaskID,
					!taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					return [AIStreamResult(type: "task_progress", text: "Task \(taskID.trimmingCharacters(in: .whitespacesAndNewlines))")]
				}
				return []
			}
			return [AIStreamResult(type: "task_progress", text: fragments.joined(separator: " — "))]
		}

		if let message = firstString(in: json, keys: ["message"]), !message.isEmpty {
			return [AIStreamResult(type: "system", text: message)]
		}
		return []
	}

	private mutating func parseAssistantMessage(_ json: [String: Any]) -> [AIStreamResult] {
		let payload = (json["message"] as? [String: Any]) ?? json
		let usageResult: AIStreamResult? = {
			guard let usage = parseUsage(payload["usage"] as? [String: Any]) else { return nil }
			return AIStreamResult(
				type: "usage",
				text: nil,
				promptTokens: usage.inputTokens,
				completionTokens: usage.outputTokens,
				contextUsedTokens: usage.contextUsedTokens
			)
		}()
		// Slice 4a: the results lane prepends the usage result before content, so
		// the normalized lane appends the usage event before any assistantText.
		if let usageEvent = normalizedUsageEvent(
			usagePayload: payload["usage"] as? [String: Any],
			messageID: firstString(in: payload, keys: ["id", "message_id", "messageId"]),
			phase: .assistantSnapshot
		) {
			pendingNormalizedEvents.append(usageEvent)
		}
		guard let content = payload["content"] as? [Any] else {
			if let fallback = extractString(payload["content"]), !fallback.isEmpty {
				var fallbackResults: [AIStreamResult] = []
				if let usageResult {
					fallbackResults.append(usageResult)
				}
				// F2.5b: this branch emitted a legacy `content` with NO normalized
				// counterpart. It needs no new core case — it is complete assistant
				// content that merely arrived as a string instead of a block array.
				// The usage event was already appended above, so appending here
				// preserves the results lane's [usage, content] order.
				pendingNormalizedEvents.append(.assistantText(.init(
					messageID: firstString(in: payload, keys: ["id", "message_id", "messageId"]),
					text: fallback,
					extra: [:]
				)))
				fallbackResults.append(AIStreamResult(type: "content", text: fallback))
				return fallbackResults
			}
			if let usageResult {
				return [usageResult]
			}
			return []
		}

		var results: [AIStreamResult] = []
		if let usageResult {
			results.append(usageResult)
		}
		for item in content {
			guard let block = item as? [String: Any], let type = block["type"] as? String else { continue }
			#if DEBUG
			if policy.reasoningEnabled {
				reasoningDebug("assistant content block type=\(type) keys=\(block.keys.sorted())")
			}
			#endif
			switch type {
			case "text":
				if let text = block["text"] as? String, !text.isEmpty {
					results.append(AIStreamResult(type: "content", text: text))
					pendingNormalizedEvents.append(.assistantText(.init(
						messageID: firstString(in: payload, keys: ["id", "message_id", "messageId"]),
						text: text, extra: [:]
					)))
				}
			case "thinking":
				guard policy.reasoningEnabled else { continue }
				if let text = block["thinking"] as? String, !text.isEmpty {
					reasoningDebug("assistant thinking block mapped len=\(text.count) snippet=\(debugSnippet(text))")
					results.append(AIStreamResult(type: "reasoning", text: nil, reasoning: text))
				} else {
					reasoningDebug("assistant thinking block missing/empty thinking field keys=\(block.keys.sorted())")
				}
			case "tool_use":
				let toolName = (block["name"] as? String) ?? "tool"
				let toolUseID = toolUseID(in: block)
				if let toolUseID, !toolUseID.isEmpty {
					toolNameByToolUseID[toolUseID] = toolName
				}
				let invocationID = resolveInvocationID(for: toolUseID)
				let rawInput = block["input"]
				let input = (rawInput as? [String: Any]) ?? [:]
				if rawInput != nil, !(rawInput is [String: Any]) {
					// Malformed known event: keep the best-effort tool_call (empty
					// args) but record that the input payload was lost.
					recordMalformedKnownEvent("non-object tool_use input")
				}
				let inputJSON = serializeJSONObjectString(input)
				results.append(
					AIStreamResult(
						type: "tool_call",
						text: nil,
						toolName: toolName,
						toolArgs: inputJSON,
						toolInvocationID: invocationID,
						toolArgsJSON: inputJSON
					)
				)
				// Slice 2: authoritative complete tool_use (projects to the tool_call).
				// F2.5: stamps the SAME invocationID the results lane just used, rather
				// than leaving the normalized lane to re-derive one it cannot.
				pendingNormalizedEvents.append(.toolUse(.init(
					messageID: firstString(in: payload, keys: ["id", "message_id", "messageId"]),
					blockIndex: nil,
					toolID: toolUseID,
					invocationID: invocationID,
					name: toolName,
					input: inputJSON,
					source: .complete,
					extra: [:]
				)))
			case "tool_result":
				let toolUseID = toolUseID(in: block)
				let toolName = resolveToolName(
					rawName: block["name"] as? String,
					toolUseID: toolUseID
				)
				let isError = inferToolResultError(from: block, toolName: toolName)
				let output = serializeToolResultContent(block["content"])
				let invocationID = resolveInvocationID(for: toolUseID)
				pendingNormalizedEvents.append(.toolResult(.init(
					toolUseID: toolUseID, toolName: toolName, invocationID: invocationID,
					output: output, isError: isError, extra: [:]
				)))
				results.append(
					AIStreamResult(
						type: "tool_result",
						text: nil,
						toolName: toolName,
						toolOutput: output,
						toolInvocationID: invocationID,
						toolResultJSON: output,
						toolIsError: isError
					)
				)
			default:
				// Unknown content block inside a known message: preserve as a
				// redacted diagnostic; sibling known blocks still emit results.
				recordMalformedKnownEvent("unknown assistant content block type=\(type)")
				continue
			}
		}
		return results
	}

	private mutating func parseUserMessage(_ json: [String: Any]) -> [AIStreamResult] {
		let payload = (json["message"] as? [String: Any]) ?? json
		guard let content = payload["content"] as? [Any] else { return [] }
		var results: [AIStreamResult] = []
		for item in content {
			guard let block = item as? [String: Any],
				let type = block["type"] as? String,
				type == "tool_result"
			else {
				continue
			}
			let toolUseID = toolUseID(in: block)
			let toolName = resolveToolName(
				rawName: block["name"] as? String,
				toolUseID: toolUseID
			)
			let isError = inferToolResultError(from: block, toolName: toolName)
			let output = serializeToolResultContent(block["content"])
			let invocationID = resolveInvocationID(for: toolUseID)
			pendingNormalizedEvents.append(.toolResult(.init(
				toolUseID: toolUseID, toolName: toolName, invocationID: invocationID,
				output: output, isError: isError, extra: [:]
			)))
			results.append(
				AIStreamResult(
					type: "tool_result",
					text: nil,
					toolName: toolName,
					toolOutput: output,
					toolInvocationID: invocationID,
					toolResultJSON: output,
					toolIsError: isError
				)
			)
		}
		return results
	}

	private mutating func parseStreamEvent(_ json: [String: Any]) -> [AIStreamResult] {
		guard let event = json["event"] as? [String: Any] else {
			#if DEBUG
			if policy.reasoningEnabled {
				reasoningDebug("stream_event missing event object keys=\(json.keys.sorted())")
			}
			#endif
			recordMalformedKnownEvent("stream_event missing event object")
			return []
		}
		guard let eventType = event["type"] as? String else {
			#if DEBUG
			if policy.reasoningEnabled {
				reasoningDebug("stream_event missing event.type keys=\(event.keys.sorted())")
			}
			#endif
			recordMalformedKnownEvent("stream_event missing event.type")
			return []
		}
		#if DEBUG
		if policy.reasoningEnabled {
			reasoningDebug("stream_event type=\(eventType) keys=\(event.keys.sorted())")
		}
		#endif

		switch eventType {
		case "content_block_start":
			// Begin assembling streamed tool input for a tool_use block. Text and
			// thinking starts need no state; other block types are benign no-ops.
			let index = numberToInt(event["index"]) ?? 0
			if let contentBlock = event["content_block"] as? [String: Any],
				(contentBlock["type"] as? String) == "tool_use" {
				toolInputAssembler.beginBlock(
					messageID: currentStreamMessageID,
					blockIndex: index,
					toolUseID: firstString(in: contentBlock, keys: ["id"]),
					toolName: firstString(in: contentBlock, keys: ["name"])
				)
			}
			return []

		case "content_block_delta":
			guard let delta = event["delta"] as? [String: Any], let deltaType = delta["type"] as? String else {
				#if DEBUG
				if policy.reasoningEnabled {
					reasoningDebug("content_block_delta missing delta/type keys=\(event.keys.sorted())")
				}
				#endif
				recordMalformedKnownEvent("content_block_delta missing delta/type")
				return []
			}
			#if DEBUG
			if policy.reasoningEnabled {
				reasoningDebug("content_block_delta deltaType=\(deltaType) deltaKeys=\(delta.keys.sorted())")
			}
			#endif
			switch deltaType {
			case "text_delta":
				if let text = delta["text"] as? String, !text.isEmpty {
					// F2.5b: one normalized event per CHUNK, mirroring the one
					// `content` result per chunk the results lane emits. The
					// complete-assistant producer is deliberately left alone — it
					// emits its own `.assistantText`, and the resulting duplicate is
					// real provider behavior that must not be deduplicated.
					pendingNormalizedEvents.append(.stream(.contentDelta(
						messageID: currentStreamMessageID,
						blockIndex: numberToInt(event["index"]),
						text: text,
						extra: [:]
					)))
					return [AIStreamResult(type: "content", text: text)]
				}
			case "thinking_delta":
				guard policy.reasoningEnabled else { return [] }
				if let text = delta["thinking"] as? String, !text.isEmpty {
					reasoningDebug("thinking_delta mapped len=\(text.count) snippet=\(debugSnippet(text))")
					return [AIStreamResult(type: "reasoning", text: nil, reasoning: text)]
				}
				reasoningDebug("thinking_delta missing/empty thinking field deltaKeys=\(delta.keys.sorted())")
			case "input_json_delta":
				// Concatenate tool-input fragments by message + block index; parse
				// only at block stop. Overflow yields a non-fatal diagnostic.
				let index = numberToInt(event["index"]) ?? 0
				let fragment = delta["partial_json"] as? String ?? ""
				if case let .malformed(messageID, blockIndex, _, _, rawBuffer) =
					toolInputAssembler.appendPartialJSON(
						messageID: currentStreamMessageID, blockIndex: index, fragment: fragment) {
					recordMalformedToolInput(messageID: messageID, blockIndex: blockIndex, rawBuffer: rawBuffer)
				}
				return []
			default:
				#if DEBUG
				if policy.reasoningEnabled {
					reasoningDebug("unsupported content_block_delta deltaType=\(deltaType)")
				}
				#endif
				recordMalformedKnownEvent("unknown content_block_delta type=\(deltaType)")
			}
			return []

		case "content_block_stop":
			// Reset-at-block-stop. Slice 1 does not emit a duplicate tool_call on
			// success (the complete assistant message stays authoritative); a
			// malformed completion becomes a diagnostic.
			let index = numberToInt(event["index"]) ?? 0
			switch toolInputAssembler.finishBlock(messageID: currentStreamMessageID, blockIndex: index) {
			case let .malformed(messageID, blockIndex, _, _, rawBuffer):
				recordMalformedToolInput(messageID: messageID, blockIndex: blockIndex, rawBuffer: rawBuffer)
			case let .assembled(assembled):
				// Slice 2: surface the assembled streamed tool input as a normalized
				// event (projects to nothing; the complete message stays authoritative).
				//
				// F2.5 stamps identity here too, so a streamed block and the complete
				// message that follows it agree on ONE invocation. Resolving here may
				// mint the UUID earlier than the results lane would have, which is
				// immaterial: the map memoizes by tool_use_id, so the complete message
				// reuses this exact value, and the value itself is random either way.
				pendingNormalizedEvents.append(.toolUse(.init(
					messageID: assembled.messageID,
					blockIndex: assembled.blockIndex,
					toolID: assembled.toolUseID,
					invocationID: resolveInvocationID(for: assembled.toolUseID),
					name: assembled.toolName ?? "tool",
					input: serializeJSONObjectString(assembled.input),
					source: .streamed,
					extra: [:]
				)))
			case .none:
				break
			}
			return []

		case "message_start":
			// New message generation: establish the block-assembly key.
			let message = event["message"] as? [String: Any]
			currentStreamMessageID = message.flatMap { firstString(in: $0, keys: ["id", "message_id", "messageId"]) }
				?? currentEnvelope?.messageID
			if let message, let usage = parseUsage(message["usage"] as? [String: Any]) {
				if let usageEvent = normalizedUsageEvent(
					usagePayload: message["usage"] as? [String: Any],
					messageID: currentStreamMessageID,
					phase: .assistantSnapshot
				) {
					pendingNormalizedEvents.append(usageEvent)
				}
				return [
					AIStreamResult(
						type: "usage",
						text: nil,
						promptTokens: usage.inputTokens,
						completionTokens: usage.outputTokens,
						contextUsedTokens: usage.contextUsedTokens
					)
				]
			}
			return []

		case "message_delta":
			var results: [AIStreamResult] = []
			if let usage = parseUsage(event["usage"] as? [String: Any]) {
				if let usageEvent = normalizedUsageEvent(
					usagePayload: event["usage"] as? [String: Any],
					messageID: currentStreamMessageID,
					phase: .assistantSnapshot
				) {
					pendingNormalizedEvents.append(usageEvent)
				}
				results.append(
					AIStreamResult(
						type: "usage",
						text: nil,
						promptTokens: usage.inputTokens,
						completionTokens: usage.outputTokens,
						contextUsedTokens: usage.contextUsedTokens
					)
				)
			}
			if let delta = event["delta"] as? [String: Any],
				let stopReason = firstString(in: delta, keys: ["stop_reason", "stopReason"]),
				!stopReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				// Appended AFTER the usage event above, so the projection replays
				// [usage, message_stop] in the order the results lane produces them.
				// Order is a compared field of the goldens, not an incidental detail.
				pendingNormalizedEvents.append(.stream(.messageDeltaStop(
					messageID: currentStreamMessageID,
					stopReason: stopReason,
					extra: [:]
				)))
				results.append(AIStreamResult(type: "message_stop", text: nil, stopReason: stopReason))
			}
			return results

		case "message_stop":
			// Reset-at-message-stop: drop any partial tool-input for this message.
			// Reset FIRST, exactly as before — the normalized emission is additive
			// and must not reorder existing state handling.
			toolInputAssembler.resetMessage(messageID: currentStreamMessageID)
			pendingNormalizedEvents.append(.stream(.messageStop(
				messageID: currentStreamMessageID,
				extra: [:]
			)))
			return [AIStreamResult(type: "message_stop", text: nil)]

		default:
			// Unknown stream event type: preserve as a redacted diagnostic.
			recordMalformedKnownEvent("unknown stream_event type=\(eventType)")
			return []
		}
	}

	private mutating func parseTopLevelToolUse(_ json: [String: Any]) -> [AIStreamResult] {
		let toolName = firstString(in: json, keys: ["tool_name", "toolName", "name"]) ?? "tool"
		let toolUseID = toolUseID(in: json)
		if let toolUseID, !toolUseID.isEmpty {
			toolNameByToolUseID[toolUseID] = toolName
		}
		let invocationID = resolveInvocationID(for: toolUseID)
		let args = extractDictionary(json["tool_args"] ?? json["toolArgs"] ?? json["input"] ?? json["arguments"])
		let argsJSON = serializeJSONObjectString(args)
		// Top-level tool_use is a COMPLETE invocation, like the assistant-embedded
		// block, so it projects to a tool_call.
		pendingNormalizedEvents.append(.toolUse(.init(
			messageID: nil, blockIndex: nil, toolID: toolUseID,
			invocationID: invocationID, name: toolName, input: argsJSON,
			source: .complete, extra: [:]
		)))
		return [AIStreamResult(type: "tool_call", text: nil, toolName: toolName, toolArgs: argsJSON, toolInvocationID: invocationID, toolArgsJSON: argsJSON)]
	}

	private mutating func parseTopLevelToolResult(_ json: [String: Any]) -> [AIStreamResult] {
		let toolUseID = toolUseID(in: json)
		let resultPayload = json["tool_result"]
			?? json["toolResult"]
			?? json["content"]
			?? json["result"]
			?? json["output"]
			?? json["response"]
		let output = serializeToolResultContent(resultPayload)
		let toolName = resolveToolName(
			rawName: firstString(in: json, keys: ["tool_name", "toolName", "name"]),
			toolUseID: toolUseID
		)
		let invocationID = resolveInvocationID(for: toolUseID)
		let isError = inferToolResultError(from: json, toolName: toolName, resultPayload: resultPayload)
		pendingNormalizedEvents.append(.toolResult(.init(
			toolUseID: toolUseID, toolName: toolName, invocationID: invocationID,
			output: output, isError: isError, extra: [:]
		)))
		return [AIStreamResult(type: "tool_result", text: nil, toolName: toolName, toolOutput: output, toolInvocationID: invocationID, toolResultJSON: output, toolIsError: isError)]
	}

	private mutating func parseResultMessage(_ json: [String: Any]) -> [AIStreamResult] {
		// Reset-at-result: the turn is closing; drop any partial tool-input blocks.
		toolInputAssembler.resetAll()
		let usage = parseUsage(json["usage"] as? [String: Any])
		let modelContextWindow = parseModelContextWindow(json["modelUsage"] as? [String: Any])
		let cost = json["total_cost_usd"] as? Double
		let stopReason = firstString(in: json, keys: ["stop_reason", "stopReason"])
		let resultSubtype = firstString(in: json, keys: ["subtype"])?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		let isError = boolValue(in: json, keys: ["is_error", "isError"]) == true
		let resultSessionID = firstString(in: json, keys: ["session_id", "sessionId"])
		if let resultSessionID {
			cliSessionID = resultSessionID
		}

		var results: [AIStreamResult] = []
		let resultErrors = extractResultErrorMessages(from: json)
		let shouldEmitResultError = isError
			|| (resultSubtype?.contains("error") ?? false)
			|| !resultErrors.isEmpty
		let shouldSuppressResultError = shouldSuppressResultErrorEmission(
			subtype: resultSubtype,
			stopReason: stopReason,
			errors: resultErrors
		)
		if shouldEmitResultError,
			!shouldSuppressResultError,
			let errorMessage = resultErrors.first,
			!errorMessage.isEmpty {
			results.append(AIStreamResult(type: "error", text: errorMessage))
		}
		if let finalText = json["result"] as? String, !finalText.isEmpty {
			results.append(AIStreamResult(type: "final_content", text: finalText))
		}
		// Note: contextUsedTokens is intentionally nil here. Claude's result.usage is an aggregate
		// billed-turn total, not a live context snapshot. Live context snapshots come from stream
		// usage events (message_start / message_delta) and are tracked separately by the estimator.
		results.append(
			AIStreamResult(
				type: "message_stop",
				text: nil,
				promptTokens: usage?.inputTokens,
				completionTokens: usage?.outputTokens,
				cost: cost,
				providerSessionID: cliSessionID,
				stopReason: stopReason,
				modelContextWindow: modelContextWindow
			)
		)
		// Slice 4a: the billed-turn aggregate is a distinct normalized fact from the
		// result itself. It is emitted immediately BEFORE `.result` so the pure
		// projection can rejoin the two into the single `message_stop` the results
		// lane produces. Note the results lane sets contextUsedTokens nil here —
		// an aggregate is not a live context snapshot — and the projection honors
		// that, even though the breakdown itself can derive one.
		// Replay-safety hinges on a STABLE identity here. Falling back to the
		// ordinal counter would mint a fresh identity on every replay of the same
		// result frame, so the aggregate would never dedupe — the one place dedup
		// matters most. `uuid` when present, else the turn index, both of which are
		// stable across replays and distinct between turns of one session.
		let turnAggregateID = firstString(in: json, keys: ["uuid", "id"])
			?? numberToInt(json["num_turns"]).map { "turn-\($0)" }
		if let usageEvent = normalizedUsageEvent(
			usagePayload: json["usage"] as? [String: Any],
			messageID: turnAggregateID,
			phase: .turnAggregate,
			modelContextWindow: modelContextWindow,
			costUSD: cost
		) {
			pendingNormalizedEvents.append(usageEvent)
		}
		pendingNormalizedEvents.append(.result(.init(
			sessionID: cliSessionID,
			subtype: resultSubtype,
			isError: isError,
			text: (json["result"] as? String).flatMap { $0.isEmpty ? nil : $0 },
			// Same `stopReason` the results-lane message_stop above is stamped with,
			// from the same parse. Reading it once and using it for both lanes is
			// what keeps them from drifting.
			stopReason: stopReason,
			extra: [:]
		)))
		return results
	}

	private mutating func parseToolProgressMessage(_ json: [String: Any]) -> [AIStreamResult] {
		let toolName = firstString(in: json, keys: ["tool_name", "toolName", "name"])
		let status = firstString(in: json, keys: ["status", "stage"])
		let detail = firstString(in: json, keys: ["message", "text", "progress"])
		let fragments = [toolName, status, detail].compactMap { value -> String? in
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
				return nil
			}
			return value
		}
		guard !fragments.isEmpty else { return [] }
		let text = fragments.joined(separator: " — ")
		let progressToolUseID = toolUseID(in: json)
		pendingNormalizedEvents.append(.toolProgress(.init(
			toolUseID: progressToolUseID,
			invocationID: resolveInvocationID(for: progressToolUseID),
			toolName: toolName, status: status, detail: detail, extra: [:]
		)))
		return [AIStreamResult(type: "tool_progress", text: text, toolName: toolName)]
	}

	private mutating func parseAuthStatusMessage(_ json: [String: Any]) -> [AIStreamResult] {
		if let isAuthenticating = json["isAuthenticating"] as? Bool {
			let output = (json["output"] as? [String])?
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
				.joined(separator: " ")
			let error = firstString(in: json, keys: ["error"])
			var fragments: [String] = [isAuthenticating ? "Authenticating" : "Authenticated"]
			if let output, !output.isEmpty {
				fragments.append(output)
			}
			if let error, !error.isEmpty {
				fragments.append(error)
			}
			let text = fragments.joined(separator: " — ")
			pendingNormalizedEvents.append(.telemetry(.authStatus(
				isAuthenticating: isAuthenticating,
				output: (json["output"] as? [String])?
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty } ?? [],
				error: error,
				status: nil,
				message: nil,
				extra: [:]
			)))
			return [AIStreamResult(type: "auth_status", text: text)]
		}

		let status = firstString(in: json, keys: ["status", "auth_status", "authStatus"])
		let message = firstString(in: json, keys: ["message", "text", "detail"])
		let parts = [status, message].compactMap { value -> String? in
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
				return nil
			}
			return value
		}
		guard !parts.isEmpty else { return [] }
		let text = parts.joined(separator: " — ")
		pendingNormalizedEvents.append(.telemetry(.authStatus(
			isAuthenticating: nil, output: [], error: nil,
			status: status, message: message, extra: [:]
		)))
		return [AIStreamResult(type: "auth_status", text: text)]
	}

	private mutating func parseToolUseSummaryMessage(_ json: [String: Any]) -> [AIStreamResult] {
		guard let summary = firstString(in: json, keys: ["summary"]), !summary.isEmpty else {
			return []
		}
		let toolUseID = toolUseID(in: json)
		pendingNormalizedEvents.append(.tool(.summary(
			toolUseID: toolUseID,
			invocationID: resolveInvocationID(for: toolUseID),
			summary: summary,
			extra: [:]
		)))
		return [AIStreamResult(type: "system", text: "Tool summary — \(summary)")]
	}

	private mutating func parseRateLimitEventMessage(_ json: [String: Any]) -> [AIStreamResult] {
		guard let info = json["rate_limit_info"] as? [String: Any] else { return [] }
		let status = firstString(in: info, keys: ["status"])?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		let rateLimitType = firstString(in: info, keys: ["rateLimitType", "rate_limit_type"])
		let overageStatus = firstString(in: info, keys: ["overageStatus", "overage_status"])
		// Emitted BEFORE the "allowed" guard, deliberately. Core carries the routine
		// status verbatim so the fact survives decoding; the projection suppresses it
		// to match the results lane. Guarding first would discard it permanently.
		pendingNormalizedEvents.append(.telemetry(.rateLimit(
			status: status, rateLimitType: rateLimitType,
			overageStatus: overageStatus, extra: [:]
		)))
		// "allowed" is a routine telemetry event and should not clutter transcript UI.
		guard status != "allowed" else { return [] }
		let fragments = ["Rate limit", status, rateLimitType, overageStatus]
			.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		guard !fragments.isEmpty else { return [] }
		return [AIStreamResult(type: "system", text: fragments.joined(separator: " — "))]
	}

	private func firstString(in json: [String: Any], keys: [String]) -> String? {
		for key in keys {
			if let value = json[key] as? String, !value.isEmpty {
				return value
			}
		}
		return nil
	}

	private func extractResultErrorMessages(from json: [String: Any]) -> [String] {
		var messages: [String] = []

		if let errors = json["errors"] as? [Any] {
			for entry in errors {
				switch entry {
				case let message as String:
					let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
					if !trimmed.isEmpty {
						messages.append(trimmed)
					}
				case let object as [String: Any]:
					if let message = firstString(in: object, keys: ["message", "error"])?
						.trimmingCharacters(in: .whitespacesAndNewlines),
						!message.isEmpty {
						messages.append(message)
					}
				default:
					continue
				}
			}
		}

		if let explicit = firstString(in: json, keys: ["error", "message"])?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!explicit.isEmpty,
			!messages.contains(explicit) {
			messages.append(explicit)
		}

		return messages
	}

	private func shouldSuppressResultErrorEmission(
		subtype: String?,
		stopReason: String?,
		errors: [String]
	) -> Bool {
		guard !errors.isEmpty else { return false }
		if isInterruptedTurnSignal(subtype) || isInterruptedTurnSignal(stopReason) {
			return true
		}
		let normalizedErrors = errors
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
			.filter { !$0.isEmpty }
		guard !normalizedErrors.isEmpty else { return false }
		// Suppress when ALL errors are recognizable abort/interrupt artifacts.
		// This covers JSON parse errors from killed tool processes, the bundled CLI
		// stack trace variant, non-fatal lock warnings, and MCP abort errors.
		return normalizedErrors.allSatisfy { message in
			isInterruptedTurnSignal(message) || ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
		}
	}

	private func isInterruptedTurnSignal(_ value: String?) -> Bool {
		guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			!value.isEmpty else {
			return false
		}
		return value.contains("interrupt")
			|| value.contains("cancel")
			|| value.contains("aborted")
			|| value.contains("request was aborted")
	}

	private func toolUseID(in json: [String: Any]) -> String? {
		firstString(in: json, keys: ["tool_use_id", "toolUseId", "toolUseID", "id"])
	}

	private mutating func resolveToolName(rawName: String?, toolUseID: String?) -> String {
		let trimmedRaw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
		let mapped = toolUseID.flatMap { toolNameByToolUseID[$0] }
		let resolved = trimmedRaw?.isEmpty == false ? trimmedRaw! : (mapped ?? "tool")
		if let toolUseID, !toolUseID.isEmpty,
			!resolved.isEmpty,
			resolved != "tool" {
			toolNameByToolUseID[toolUseID] = resolved
		}
		return resolved
	}

	private func inferToolResultError(
		from payload: [String: Any],
		toolName: String,
		resultPayload: Any? = nil
	) -> Bool? {
		if policy.isExternallyTrackedTool(toolName) {
			// The host tracks this tool's final status in its completion handler.
			return nil
		}

		if let explicit = boolValue(in: payload, keys: ["is_error", "isError"]) {
			return explicit
		}
		if let inferred = inferToolResultErrorSignal(from: payload) {
			return inferred
		}
		if let inferred = inferToolResultErrorSignal(from: resultPayload) {
			return inferred
		}
		return nil
	}

	private func inferToolResultErrorSignal(from value: Any?) -> Bool? {
		switch value {
		case let object as [String: Any]:
			return inferToolResultErrorSignal(fromObject: object)
		case let array as [Any]:
			var sawSuccessSignal = false
			for element in array {
				if let inferred = inferToolResultErrorSignal(from: element) {
					if inferred {
						return true
					}
					sawSuccessSignal = true
				}
			}
			return sawSuccessSignal ? false : nil
		case let text as String:
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
				|| (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
				let data = trimmed.data(using: .utf8),
				let json = try? JSONSerialization.jsonObject(with: data) {
				return inferToolResultErrorSignal(from: json)
			}
			return nil
		default:
			return nil
		}
	}

	private func inferToolResultErrorSignal(fromObject object: [String: Any]) -> Bool? {
		if let explicit = boolValue(in: object, keys: ["is_error", "isError"]) {
			return explicit
		}

		if let status = firstString(in: object, keys: ["status", "result", "outcome", "state", "subtype"]),
			let statusInference = inferStatusError(from: status) {
			return statusInference
		}

		if let exitCode = intValue(in: object, keys: ["exitCode", "exit_code", "code"]) {
			if exitCode == 0 { return false }
			if exitCode > 0 { return true }
		}

		if let error = firstString(in: object, keys: ["error", "error_message", "errorMessage"]),
			!error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		if let errors = object["errors"] as? [Any], !errors.isEmpty {
			return true
		}
		if boolValue(in: object, keys: ["success", "ok"]) == true {
			return false
		}

		let nestedKeys = [
			"tool_result", "toolResult", "result", "output", "response",
			"content", "payload", "data", "value", "tool_use_result", "toolUseResult"
		]
		for key in nestedKeys {
			if let inferred = inferToolResultErrorSignal(from: object[key]) {
				return inferred
			}
		}

		if let contentBlocks = object["content"] as? [Any], !contentBlocks.isEmpty {
			return false
		}
		return nil
	}

	private func inferStatusError(from value: String) -> Bool? {
		switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "ok", "success", "succeeded", "complete", "completed":
			return false
		case "error", "failed", "failure", "rejected", "denied", "cancelled", "canceled":
			return true
		default:
			return nil
		}
	}

	private func boolValue(in object: [String: Any], keys: [String]) -> Bool? {
		for key in keys {
			if let value = object[key] as? Bool {
				return value
			}
			if let number = object[key] as? NSNumber {
				return number.boolValue
			}
			if let text = object[key] as? String {
				switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
				case "true", "1", "yes", "y":
					return true
				case "false", "0", "no", "n":
					return false
				default:
					break
				}
			}
		}
		return nil
	}

	private func intValue(in object: [String: Any], keys: [String]) -> Int? {
		for key in keys {
			if let value = object[key] as? Int {
				return value
			}
			if let number = object[key] as? NSNumber {
				return number.intValue
			}
			if let text = object[key] as? String,
				let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
				return parsed
			}
		}
		return nil
	}

	private mutating func resolveInvocationID(for toolUseID: String?) -> UUID? {
		guard let toolUseID, !toolUseID.isEmpty else { return nil }
		if let existing = invocationIDByToolUseID[toolUseID] {
			return existing
		}
		let generated = UUID()
		invocationIDByToolUseID[toolUseID] = generated
		return generated
	}

	private func serializeJSONObjectString(_ value: [String: Any]) -> String? {
		guard !value.isEmpty, JSONSerialization.isValidJSONObject(value) else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}

	private func serializeToolResultContent(_ value: Any?) -> String {
		guard let value else { return "" }
		if let text = value as? String {
			return text
		}
		if let blocks = value as? [[String: Any]] {
			let textBlocks = blocks.compactMap { block -> String? in
				let blockType = (block["type"] as? String)?.lowercased()
				if blockType == "text" || blockType == "output_text" {
					return block["text"] as? String
				}
				return nil
			}
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
			if !textBlocks.isEmpty {
				return textBlocks.joined(separator: "\n")
			}
		}
		if JSONSerialization.isValidJSONObject(value),
		   let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
		   let text = String(data: data, encoding: .utf8) {
			return text
		}
		return String(describing: value)
	}

	private func extractString(_ value: Any?) -> String? {
		switch value {
		case let string as String:
			return string
		case let dict as [String: Any]:
			if let text = dict["text"] as? String { return text }
			return nil
		case let array as [Any]:
			return array.compactMap { extractString($0) }.joined(separator: "")
		default:
			return nil
		}
	}

	private func extractDictionary(_ value: Any?) -> [String: Any] {
		value as? [String: Any] ?? [:]
	}

	private func parseModelContextWindow(_ value: [String: Any]?) -> Int? {
		guard let value else { return nil }
		for (_, usageAny) in value {
			guard let usage = usageAny as? [String: Any] else { continue }
			if let contextWindow = numberToInt(usage["contextWindow"]), contextWindow > 0 {
				return contextWindow
			}
		}
		return nil
	}

	/// Slice 4a: cache-aware breakdown for the NORMALIZED lane. The results lane
	/// keeps using `parseUsage` unchanged — 4a changes no production behavior.
	/// This is the single cache-aware parser in the app (boundary rule R11a);
	/// `parseUsage` below derives its aggregate from the same fields.
	private func parseUsageBreakdown(_ value: [String: Any]?) -> ClaudeUsageBreakdown? {
		guard let value else { return nil }
		let input = numberToInt(value["input_tokens"]) ?? numberToInt(value["inputTokens"])
		let output = numberToInt(value["output_tokens"]) ?? numberToInt(value["outputTokens"])
		let cacheRead = numberToInt(value["cache_read_input_tokens"]) ?? numberToInt(value["cacheReadInputTokens"])
		let cacheCreation = numberToInt(value["cache_creation_input_tokens"]) ?? numberToInt(value["cacheCreationInputTokens"])
		guard input != nil || output != nil || cacheRead != nil || cacheCreation != nil else { return nil }
		return ClaudeUsageBreakdown(
			inputTokens: input ?? 0,
			outputTokens: output ?? 0,
			cacheCreationInputTokens: cacheCreation ?? 0,
			cacheReadInputTokens: cacheRead ?? 0
		)
	}

	/// Monotonic per-translator counter disambiguating usage payloads that arrive
	/// without a message id. Ignored by `ClaudeUsageIdentity` when an id exists.
	private mutating func nextUsageOrdinal() -> Int {
		usageOrdinalCounter += 1
		return usageOrdinalCounter
	}

	/// Builds the normalized usage event for a payload, or nil when it carries no
	/// usage fields. `contextUsedTokens` semantics are the breakdown's own.
	private mutating func normalizedUsageEvent(
		usagePayload: [String: Any]?,
		messageID: String?,
		phase: ClaudeUsagePhase,
		modelContextWindow: Int? = nil,
		costUSD: Double? = nil
	) -> ClaudeRuntimeEvent? {
		guard let breakdown = parseUsageBreakdown(usagePayload) else { return nil }
		return .usage(.init(
			identity: ClaudeUsageIdentity(
				sessionID: cliSessionID,
				messageID: messageID,
				phase: phase,
				ordinal: messageID == nil ? nextUsageOrdinal() : nil
			),
			// Slice 4a emits top-level scope only. Child/subagent attribution has no
			// producer yet — the results lane folds subagent tokens into the parent
			// (pinned as an absence). Wiring the producer is 4b/lifecycle work.
			scope: .topLevel,
			breakdown: breakdown,
			modelContextWindow: modelContextWindow,
			costUSD: costUSD,
			extra: [:]
		))
	}

	private func parseUsage(_ value: [String: Any]?) -> ParsedTokenUsage? {
		guard let value else { return nil }

		let input = numberToInt(value["input_tokens"]) ?? numberToInt(value["inputTokens"])
		let output = numberToInt(value["output_tokens"]) ?? numberToInt(value["outputTokens"])
		let cacheRead = numberToInt(value["cache_read_input_tokens"]) ?? numberToInt(value["cacheReadInputTokens"])
		let cacheCreation = numberToInt(value["cache_creation_input_tokens"]) ?? numberToInt(value["cacheCreationInputTokens"])

		let hasAnyUsageField = input != nil || output != nil || cacheRead != nil || cacheCreation != nil
		guard hasAnyUsageField else { return nil }

		let normalizedInput = max(0, input ?? 0)
		let normalizedOutput = max(0, output ?? 0)
		let hasContextBreakdown = input != nil || cacheRead != nil || cacheCreation != nil
		let contextUsedTokens: Int? = hasContextBreakdown
			? max(0, normalizedInput + max(0, cacheRead ?? 0) + max(0, cacheCreation ?? 0))
			: nil

		return ParsedTokenUsage(
			inputTokens: normalizedInput,
			outputTokens: normalizedOutput,
			contextUsedTokens: contextUsedTokens
		)
	}

	private func numberToInt(_ value: Any?) -> Int? {
		switch value {
		case let int as Int:
			return int
		case let double as Double:
			return Int(double)
		case let string as String:
			return Int(string)
		default:
			return nil
		}
	}
}

private struct ParsedTokenUsage {
	let inputTokens: Int
	let outputTokens: Int
	let contextUsedTokens: Int?
}
