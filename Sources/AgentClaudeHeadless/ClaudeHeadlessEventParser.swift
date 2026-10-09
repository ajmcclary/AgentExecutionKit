import Foundation
import AIClientKit
import ProcessStreamFraming

/// Stateless parser for the headless CLI dialect. Native SDK session events use
/// AgentClaudeProtocol; the two dialects retain their different projection rules.
public struct ClaudeHeadlessEventParser: Sendable {
    private let reasoningEnabled: Bool
    private let enableDebugLogging: Bool
    private let diagnostics: @Sendable (String) -> Void
    public init(reasoningEnabled: Bool, enableDebugLogging: Bool = false,
                diagnostics: @escaping @Sendable (String) -> Void = { _ in }) {
        self.reasoningEnabled = reasoningEnabled
        self.enableDebugLogging = enableDebugLogging
        self.diagnostics = diagnostics
    }
	public func parseStreamEvents(_ lineData: Data) throws -> [AIStreamResult] {
		guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return [] }
		let raw = try JSONSerialization.jsonObject(with: trimmed)
		if let json = raw as? [String: Any] {
			let events = parseEventDictionary(json)
			return events.map(mapToAIStreamResult)
		} else if let array = raw as? [Any] {
			var events: [AgentStreamEvent] = []
			for element in array {
				guard let dict = element as? [String: Any] else {
					if enableDebugLogging,
					   let snippet = String(data: trimmed.prefix(100), encoding: .utf8) {
						diagnostics("[DEBUG] ClaudeCodeAgent: Skipping non-dictionary entry in array payload: \(snippet)")
					}
					continue
				}
				let parsed = parseEventDictionary(dict)
				events.append(contentsOf: parsed)
			}
			return events.map(mapToAIStreamResult)
		} else {
			if enableDebugLogging,
			   let snippet = String(data: trimmed.prefix(100), encoding: .utf8) {
				diagnostics("[DEBUG] ClaudeCodeAgent: Unsupported JSON payload: \(snippet)")
			}
			return []
		}
	}

	/// Parse a single event dictionary into one or more AgentStreamEvents.
	/// Returns an array because some events (like `result`) emit multiple events.
	private func parseEventDictionary(_ json: [String: Any]) -> [AgentStreamEvent] {
		guard let type = json["type"] as? String else {
			if enableDebugLogging {
				diagnostics("[DEBUG] ClaudeCodeAgent: Missing type field in event payload")
			}
			return []
		}
		if enableDebugLogging {
			diagnostics("[DEBUG] ClaudeCodeAgent: Parsing event type: \(type)")
		}
		switch type {
		case "init":
			return [.lifecycle(.initialized)]
		case "message", "assistant":
			// Claude Code CLI format: content is nested at message.content as array of blocks.
			if let messageObj = json["message"] as? [String: Any],
			   let contentArray = messageObj["content"] as? [[String: Any]] {
				var events: [AgentStreamEvent] = []
				for block in contentArray {
					switch block["type"] as? String {
					case "text":
						if let text = block["text"] as? String, !text.isEmpty {
							events.append(.message(content: text, reasoning: nil))
						}
					case "thinking":
						guard reasoningEnabled else { continue }
						if let thinking = block["thinking"] as? String, !thinking.isEmpty {
							events.append(.message(content: "", reasoning: thinking))
						}
					case "tool_use":
						let name = (block["name"] as? String) ?? "tool"
						let args = (block["input"] as? [String: Any]) ?? [:]
						events.append(.toolCall(name: name, args: args))
					case "tool_result":
						let name = ClaudeEventParser.extractString(block["name"]) ?? "tool"
						let output = ClaudeEventParser.extractString(block["content"])
							?? encodeAnyToJSON(block["content"])
							?? ""
						events.append(.toolResult(name: name, result: output))
					default:
						continue
					}
				}
				if events.isEmpty {
					if enableDebugLogging {
						diagnostics("[DEBUG] ClaudeCodeAgent: Skipping empty assistant message")
					}
					return []
				}
				return events
			} else {
				// Fallback to old format for compatibility
				let content = ClaudeEventParser.extractString(json["content"]) ?? ""
				let reasoning = reasoningEnabled ? ClaudeEventParser.extractString(json["reasoning"]) : nil
				if !content.isEmpty || reasoning != nil {
					return [.message(content: content, reasoning: reasoning)]
				}
				if enableDebugLogging {
					diagnostics("[DEBUG] ClaudeCodeAgent: Skipping empty assistant message")
				}
				return []
			}
		case "tool_use":
			let name = ClaudeEventParser.extractString(json["tool_name"]) ?? "tool"
			let args = ClaudeEventParser.extractDictionary(json["tool_args"])
			return [.toolCall(name: name, args: args)]
		case "tool_result":
			let name = ClaudeEventParser.extractString(json["tool_name"]) ?? "tool"
			let result = ClaudeEventParser.extractString(json["tool_result"]) ?? ""
			return [.toolResult(name: name, result: result)]
		case "stream_event":
			guard
				let event = json["event"] as? [String: Any],
				let eventType = event["type"] as? String,
				eventType == "content_block_delta",
				let delta = event["delta"] as? [String: Any],
				let deltaType = delta["type"] as? String
			else {
				return []
			}
			switch deltaType {
			case "text_delta":
				guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
				return [.message(content: text, reasoning: nil)]
			case "thinking_delta":
				guard reasoningEnabled else { return [] }
				guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
				return [.message(content: "", reasoning: thinking)]
			default:
				return []
			}
		case "result":
			// Parse usage and cost
			let usageDict = json["usage"] as? [String: Any]
			let usage = ClaudeEventParser.parseUsage(usageDict)
			let cost = json["total_cost_usd"] as? Double
			let stopReason = (json["stop_reason"] as? String ?? json["stopReason"] as? String)

			// Extract session_id for resumption (check both snake_case and camelCase)
			let sessionID = json["session_id"] as? String ?? json["sessionId"] as? String
			if enableDebugLogging && sessionID != nil {
				diagnostics("[DEBUG] ClaudeCodeAgent: Captured session_id for resumption: \(sessionID!)")
			}

			// Extract final result text if present
			let finalText = json["result"] as? String

			// Build events: optional stop-reason system message, final message, then completion
			var events: [AgentStreamEvent] = []
			if let stopReason = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
			   !stopReason.isEmpty,
			   stopReason.lowercased() != "end_turn" {
				events.append(.system(message: "Claude stop reason: \(stopReason)"))
			}
			if let text = finalText, !text.isEmpty {
				events.append(.finalMessage(content: text))
			}
			events.append(.completion(usage: usage, cost: cost, providerSessionID: sessionID))
			return events
		case "system":
			// Check for subtype (e.g., "init") which doesn't have a message field
			let subtype = json["subtype"] as? String
			if subtype == "init" {
				return [.lifecycle(.initialized)]
			}
			let message = ClaudeEventParser.extractString(json["message"]) ?? ""
			// Skip empty system messages to avoid showing empty info icons
			if message.isEmpty {
				if enableDebugLogging {
					diagnostics("[DEBUG] ClaudeCodeAgent: Skipping empty system message")
				}
				return []
			}
			return [.system(message: message)]
		case "tool_progress":
			if let progress = ClaudeEventParser.extractString(json["message"]) ?? ClaudeEventParser.extractString(json["progress"]) {
				let trimmed = progress.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmed.isEmpty {
					return [.system(message: trimmed)]
				}
			}
			return []
		case "auth_status":
			let status = ClaudeEventParser.extractString(json["status"]) ?? ClaudeEventParser.extractString(json["auth_status"]) ?? ClaudeEventParser.extractString(json["authStatus"])
			let message = ClaudeEventParser.extractString(json["message"])
			let fragments = [status, message].compactMap { value -> String? in
				guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
					return nil
				}
				return value
			}
			if !fragments.isEmpty {
				return [.system(message: fragments.joined(separator: " — "))]
			}
			return []
		case "user":
			if enableDebugLogging {
				diagnostics("[DEBUG] ClaudeCodeAgent: Skipping user echo message")
			}
			return []
		default:
			if enableDebugLogging {
				diagnostics("[DEBUG] ClaudeCodeAgent: Unknown event type: \(type)")
			}
			return []
		}
	}

	private func mapToAIStreamResult(_ event: AgentStreamEvent) -> AIStreamResult {
		switch event {
		case .message(let content, let reasoning):
			if content.isEmpty, let reasoning, !reasoning.isEmpty {
				return AIStreamResult(type: "reasoning", text: nil, reasoning: reasoning)
			}
			return AIStreamResult(type: "content", text: content, reasoning: reasoning)
		case .finalMessage(let content):
			// Final authoritative message content - replaces streaming content
			return AIStreamResult(type: "final_content", text: content)
		case .toolCall(let name, let args):
			// Emit structured tool_call event with args preserved
			let argsJSON = encodeArgsToJSON(args)
			return AIStreamResult(type: "tool_call", text: nil, toolName: name, toolArgs: argsJSON, toolArgsJSON: argsJSON)
		case .toolResult(let name, let result):
			// Emit structured tool_result event with full result preserved
			return AIStreamResult(type: "tool_result", text: nil, toolName: name, toolOutput: result, toolResultJSON: result)
		case .system(let message):
			return AIStreamResult(type: "system", text: message)
		case .lifecycle(let lifecycle):
			return AIStreamResult(type: AIStreamResult.lifecycleType, text: String(describing: lifecycle))
		case .completion(let usage, let cost, let providerSessionID):
			return AIStreamResult(
				type: "message_stop",
				text: nil,
				promptTokens: usage?.inputTokens,
				completionTokens: usage?.outputTokens,
				cost: cost,
				providerSessionID: providerSessionID
			)
		}
	}

	/// Encode tool arguments dictionary to JSON string for display
	private func encodeArgsToJSON(_ args: [String: Any]) -> String? {
		guard !args.isEmpty else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
			let jsonString = String(data: data, encoding: .utf8)
		else { return nil }
		return jsonString
	}

	private func encodeAnyToJSON(_ value: Any?) -> String? {
		guard let value, JSONSerialization.isValidJSONObject(value),
			  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
		else { return nil }
		return String(data: data, encoding: .utf8)
	}

	public func extractCLIErrorDetail(fromStdout data: Data) -> String? {
		guard !data.isEmpty else { return nil }
		let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

		// First pass: look for structured JSON errors
		for slice in lines {
			let candidate = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
			if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
				if let text = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
					return text
				}
				if let text = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
					return text
				}
				if let text = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
					return text
				}
			}
		}

		// Second pass: if no JSON found, return plain-text diagnostics (common when CLI fails before JSON mode)
		for slice in lines {
			let candidate = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
			if let plainText = String(data: trimmed, encoding: .utf8) {
				let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
				// Skip empty lines and common noise
				if !cleaned.isEmpty && !cleaned.hasPrefix("{") && !cleaned.hasPrefix("[") {
					return cleaned
				}
			}
		}
		return nil
	}

}

private enum AgentStreamEvent {
    case message(content: String, reasoning: String?)
    case finalMessage(content: String)
    case toolCall(name: String, args: [String: Any])
    case toolResult(name: String, result: String)
    case system(message: String)
    case lifecycle(AgentLifecycleEvent)
    case completion(usage: TokenUsage?, cost: Double?, providerSessionID: String?)
}
private enum AgentLifecycleEvent { case initialized }
private struct TokenUsage { let inputTokens: Int; let outputTokens: Int }
private enum ClaudeEventParser {
	static func extractString(_ value: Any?) -> String? {
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

	static func extractDictionary(_ value: Any?) -> [String: Any] {
		value as? [String: Any] ?? [:]
	}

	static func parseUsage(_ value: [String: Any]?) -> TokenUsage? {
		guard let value else { return nil }
		let input = Self.numberToInt(value["input_tokens"]) ?? Self.numberToInt(value["inputTokens"])
		let output = Self.numberToInt(value["output_tokens"]) ?? Self.numberToInt(value["outputTokens"])
		if let input, let output {
			return TokenUsage(inputTokens: input, outputTokens: output)
		}
		return nil
	}

	private static func numberToInt(_ value: Any?) -> Int? {
		switch value {
		case let int as Int:
			return int
		case let double as Double:
			guard double.isFinite, double >= Double(Int.min), double < Double(Int.max) else { return nil }
			return Int(double)
		case let string as String:
			return Int(string)
		default:
			return nil
		}
	}
}
