import Foundation
import AIClientKit
import ProcessStreamFraming

public struct CodexExecEventParser: Sendable {
	private var codexItemInvocationIDs: [String: UUID] = [:]
	private let policy: CodexExecToolPolicy
	public init(policy: CodexExecToolPolicy) { self.policy = policy }
	public mutating func parseJSONLEvent(_ data: Data) -> AIStreamResult? {
		guard let trimmed = trimmedASCIIWhitespace(data) else { return nil }
		guard let raw = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else { return nil }

		// Current/legacy format (try this first): {"type":"item.completed","item":{...}}
		if let typeValue = raw["type"] as? String {
			let result = parseCurrentFormatExec(raw, typeValue: typeValue)
			if result != nil {
				return result
			}
		}

		// Newer format (fallback for future compatibility): {"id":"0","msg":{"type":"agent_message","message":"OK"}}
		if let msg = raw["msg"] as? [String: Any],
		   let msgType = msg["type"] as? String {
			return parseNewerFormatExec(msg, msgType: msgType)
		}

		if let typeValue = raw["type"] as? String,
		   typeValue == "done" || typeValue == "message_stop" {
			return AIStreamResult(type: "message_stop", text: nil)
		}

		if let message = (raw["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !message.isEmpty {
			return AIStreamResult(type: "system", text: message)
		}

		return nil
	}

	private mutating func parseCurrentFormatExec(_ raw: [String: Any], typeValue: String) -> AIStreamResult? {
		switch typeValue {
		case "item.started", "item.completed":
			guard let item = raw["item"] as? [String: Any],
				  let itemType = item["type"] as? String else { return nil }
			let isStarted = (typeValue == "item.started")
			let isCompleted = (typeValue == "item.completed")

			if isCompleted {
				switch itemType {
				case "agent_message", "message", "assistant":
					if let text = item["text"] as? String, !text.isEmpty {
						return AIStreamResult(type: "content", text: text, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
					}
				case "reasoning":
					if let text = item["text"] as? String, !text.isEmpty {
						return AIStreamResult(type: "reasoning", text: nil, reasoning: text, promptTokens: nil, completionTokens: nil, cost: nil)
					}
				default:
					break
				}
			}
			return parseCodexToolLifecycleItem(item: item, isStarted: isStarted, isCompleted: isCompleted)

		case "turn.completed":
			let usage = raw["usage"] as? [String: Any]
			let promptTokens = usage?["input_tokens"] as? Int
			let completionTokens = usage?["output_tokens"] as? Int
			let cost = raw["total_cost_usd"] as? Double
			return AIStreamResult(
				type: "message_stop",
				text: nil,
				reasoning: nil,
				promptTokens: promptTokens,
				completionTokens: completionTokens,
				cost: cost
			)

		case "error":
			let message = (raw["message"] as? String) ?? (raw["content"] as? String) ?? "Codex CLI reported an error."
			return AIStreamResult(type: "error", text: message, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)

		default:
			return nil
		}
	}

	private mutating func parseCodexToolLifecycleItem(
		item: [String: Any],
		isStarted: Bool,
		isCompleted: Bool
	) -> AIStreamResult? {
		guard let itemTypeRaw = item["type"] as? String else { return nil }
		let itemType = itemTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard itemType != "agent_message",
			  itemType != "message",
			  itemType != "assistant",
			  itemType != "reasoning",
			  itemType != "error" else { return nil }

		guard let toolName = codexToolName(from: item, itemType: itemType) else { return nil }
		guard !isExternallyTrackedItem(item: item, toolName: toolName) else { return nil }

		let itemID = (item["id"] as? String)
			?? (item["item_id"] as? String)
			?? (item["call_id"] as? String)
		let invocationID = invocationID(for: itemID)
		let argsJSON = codexToolArgsJSON(from: item, itemType: itemType)
		let resultJSON = codexToolResultJSON(from: item)
		let isError = codexItemIsError(item)

		if isStarted {
			if toolName == "bash" {
				return AIStreamResult(
					type: "tool_result",
					text: nil,
					reasoning: nil,
					promptTokens: nil,
					completionTokens: nil,
					cost: nil,
					toolName: toolName,
					toolArgs: argsJSON,
					toolOutput: resultJSON,
					toolInvocationID: invocationID,
					toolResultJSON: resultJSON,
					toolArgsJSON: argsJSON,
					toolIsError: false
				)
			}
			return AIStreamResult(
				type: "tool_call",
				text: nil,
				reasoning: nil,
				promptTokens: nil,
				completionTokens: nil,
				cost: nil,
				toolName: toolName,
				toolArgs: argsJSON,
				toolOutput: nil,
				toolInvocationID: invocationID,
				toolResultJSON: nil,
				toolArgsJSON: argsJSON,
				toolIsError: nil
			)
		}

		if isCompleted {
			if let itemID {
				_ = codexItemInvocationIDs.removeValue(forKey: itemID)
			}
			return AIStreamResult(
				type: "tool_result",
				text: nil,
				reasoning: nil,
				promptTokens: nil,
				completionTokens: nil,
				cost: nil,
				toolName: toolName,
				toolArgs: argsJSON,
				toolOutput: resultJSON,
				toolInvocationID: invocationID,
				toolResultJSON: resultJSON,
				toolArgsJSON: argsJSON,
				toolIsError: isError
			)
		}

		return nil
	}

	private mutating func invocationID(for itemID: String?) -> UUID? {
		guard let itemID, !itemID.isEmpty else { return nil }
		if let existing = codexItemInvocationIDs[itemID] { return existing }
		let created = UUID()
		codexItemInvocationIDs[itemID] = created
		return created
	}

	private func codexToolName(from item: [String: Any], itemType: String) -> String? {
		if itemType == "command_execution" || itemType == "commandexecution" || itemType.contains("command") {
			return "bash"
		}

		let candidate =
			(item["name"] as? String)
			?? (item["tool_name"] as? String)
			?? (item["toolName"] as? String)
			?? (item["function_name"] as? String)
			?? (item["functionName"] as? String)
			?? (item["tool"] as? String)
		guard let candidate, !candidate.isEmpty else { return nil }
		return normalizedToolName(candidate)
	}

	private func normalizedToolName(_ raw: String) -> String {
		let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if lowered.hasPrefix("functions.") {
			return String(lowered.dropFirst("functions.".count))
		}
		if lowered.hasPrefix("mcp__") {
			let components = lowered.components(separatedBy: "__")
			if components.count >= 3 {
				return components.dropFirst(2).joined(separator: "__")
			}
		}
		return lowered
	}

	private func codexToolArgsJSON(from item: [String: Any], itemType: String) -> String? {
		if itemType == "command_execution" || itemType == "commandexecution" || itemType.contains("command") {
			let command = (item["command"] as? String) ?? ""
			let args: [String: Any] = ["command": command]
			return encodeJSONObject(args)
		}

		if let args = item["arguments"] {
			if let argsString = args as? String, !argsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return argsString
			}
			if let json = CodexExecJSONFormatting.prettyString(from: args) {
				return json
			}
		}
		if let input = item["input"] {
			if let inputString = input as? String, !inputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return inputString
			}
			if let json = CodexExecJSONFormatting.prettyString(from: input) {
				return json
			}
		}
		return nil
	}

	private func codexToolResultJSON(from item: [String: Any]) -> String {
		encodeJSONObject(item) ?? "{}"
	}

	private func encodeJSONObject(_ object: Any) -> String? {
		CodexExecJSONFormatting.prettyString(from: object)
	}

	private func codexItemIsError(_ item: [String: Any]) -> Bool? {
		let exitCode =
			(item["exit_code"] as? Int)
			?? (item["exitCode"] as? Int)
		if let exitCode, exitCode < 0 {
			return nil
		}
		if let exitCode {
			return exitCode > 0
		}

		if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			if status == "failed" || status == "error" || status == "failure" || status == "rejected" {
				return true
			}
			if status == "completed" || status == "success" || status == "ok" || status == "running" || status == "in_progress" || status == "pending" {
				return false
			}
		}
		return nil
	}

	private func isExternallyTrackedItem(item: [String: Any], toolName: String) -> Bool {
		if policy.isExternallyTrackedToolName(toolName) {
			return true
		}
		for key in ["name", "tool_name", "toolName", "function_name", "functionName", "call_name", "callName"] {
			if let value = item[key] as? String,
				policy.isExternallyTrackedToolName(value) {
				return true
			}
		}
		for key in ["server", "server_name", "serverName", "mcp_server", "mcpServer"] {
			if let value = item[key] as? String,
				policy.isExternallyTrackedServer(value) {
				return true
			}
		}
		return false
	}

	private mutating func parseNewerFormatExec(_ msg: [String: Any], msgType: String) -> AIStreamResult? {
		switch msgType {
		case "agent_message":
			// Newer format uses "message" field instead of "text"
			if let text = msg["message"] as? String, !text.isEmpty {
				return AIStreamResult(type: "content", text: text, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
			}
			return nil

		case "agent_reasoning":
			if let text = msg["text"] as? String, !text.isEmpty {
				return AIStreamResult(type: "reasoning", text: nil, reasoning: text, promptTokens: nil, completionTokens: nil, cost: nil)
			}
			return nil

		case "token_count":
			// Newer format for usage info
			if let info = msg["info"] as? [String: Any],
			   let totalUsage = info["total_token_usage"] as? [String: Any] {
				let promptTokens = totalUsage["input_tokens"] as? Int
				let completionTokens = totalUsage["output_tokens"] as? Int
				// Cost is not in the newer format, set to nil
				return AIStreamResult(
					type: "message_stop",
					text: nil,
					reasoning: nil,
					promptTokens: promptTokens,
					completionTokens: completionTokens,
					cost: nil
				)
			}
			return nil

		default:
			return nil
		}
	}

	public func extractCLIErrorDetail(fromStdout data: Data) -> String? {
		guard !data.isEmpty else { return nil }
		let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

		// First pass: look for Codex CLI structured errors
		for slice in lines {
			let candidate = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
			if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
				// Check for Codex CLI item.completed with error type
				if json["type"] as? String == "item.completed",
				   let item = json["item"] as? [String: Any],
				   let itemType = item["type"] as? String,
				   itemType == "error",
				   let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
				   !text.isEmpty {
					return text
				}

				// Check for top-level error field
				if let text = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
					return text
				}

				// Check for message field
				if let text = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
					return text
				}
			}
		}

		// Second pass: return plain-text diagnostics (common when CLI fails before JSON mode)
		for slice in lines {
			let candidate = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
			if let plainText = String(data: trimmed, encoding: .utf8) {
				let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
				// Skip empty lines and JSON noise
				if !cleaned.isEmpty && !cleaned.hasPrefix("{") && !cleaned.hasPrefix("[") {
					return cleaned
				}
			}
		}
		return nil
	}

}
