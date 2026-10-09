import Foundation
import AIClientKit
import ProcessStreamFraming

public enum GeminiHeadlessParserError: Error, Sendable { case runtime(String) }

/// Parser state belongs to one execution. No Foundation object graph crosses
/// the public interface; tool arguments are serialized JSON.
public struct GeminiHeadlessEventParser: Sendable {
    public private(set) var providerSessionID: String?
    private let runID: UUID?
    private let enableDebugLogging: Bool
    private let diagnostics: @Sendable (String) -> Void
    public init(runID: UUID? = nil, enableDebugLogging: Bool = false,
                diagnostics: @escaping @Sendable (String) -> Void = { _ in }) {
        self.runID = runID; self.enableDebugLogging = enableDebugLogging; self.diagnostics = diagnostics
    }
	public mutating func parseStreamEvents(_ lineData: Data) throws -> [GeminiHeadlessEvent] {
		guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return [] }
		let raw = try JSONSerialization.jsonObject(with: trimmed)

		if let dict = raw as? [String: Any] {
			if let event = try parseEventDictionary(dict) {
				return [event]
			}
			return []
		} else if let array = raw as? [Any] {
			var events: [GeminiHeadlessEvent] = []
			for element in array {
				guard let dict = element as? [String: Any],
						let event = try parseEventDictionary(dict) else { continue }
				events.append(event)
			}
			return events
		} else {
			return []
		}
	}

	private mutating func parseEventDictionary(_ json: [String: Any]) throws -> GeminiHeadlessEvent? {
		guard let type = json["type"] as? String else {
			if enableDebugLogging {
				diagnostics("[GeminiAgent] parseEventDictionary: No 'type' field")
			}
			return nil
		}

		// Log event for debugging
		if enableDebugLogging {
			if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: []),
				let jsonString = String(data: jsonData, encoding: .utf8) {
				diagnostics("[GeminiAgent] Event: \(jsonString)")
			}
		}

		switch type {
		case "init":
			if let sessionID = GeminiEventParser.extractString(json["session_id"]) ?? GeminiEventParser.extractString(json["sessionId"]),
				!sessionID.isEmpty {
				providerSessionID = sessionID
			}
			if enableDebugLogging {
				diagnostics("[GeminiAgent] Init event - CLI session started (runID: \(runID?.uuidString ?? "nil"), sessionID: \(providerSessionID ?? "nil"))")
			}
			return .initialized
		case "message":
			let role = (json["role"] as? String)?.lowercased()
			if enableDebugLogging {
				diagnostics("[GeminiAgent] Message event - role: \(role ?? "nil")")
			}
			guard role == "assistant" else {
				if enableDebugLogging {
					diagnostics("[GeminiAgent] Ignoring non-assistant message")
				}
				return nil
			}
			if let content = GeminiEventParser.extractString(json["content"]) {
				if enableDebugLogging {
					diagnostics("[GeminiAgent] Assistant message - content length: \(content.count), isEmpty: \(content.isEmpty)")
				}
				if !content.isEmpty {
					return .message(content: content)
				} else {
					if enableDebugLogging {
						diagnostics("[GeminiAgent] WARNING: Assistant message with empty content - ignoring")
					}
				}
			} else {
				if enableDebugLogging {
					diagnostics("[GeminiAgent] WARNING: Could not extract content from assistant message")
				}
			}
			return nil
		case "tool_use":
			let name = GeminiEventParser.extractString(json["tool_name"]) ?? "tool"
			if enableDebugLogging {
				diagnostics("[GeminiAgent] Tool use event: \(name)")
			}
			var args = GeminiEventParser.extractDictionary(json["parameters"])
			if let toolID = json["tool_id"] as? String {
				args["tool_id"] = toolID
			}
			return .toolCall(name: name, argumentsJSON: GeminiEventParser.stringify(args) ?? "{}")
		case "tool_result":
			let identifier = GeminiEventParser.extractString(json["tool_id"]) ?? GeminiEventParser.extractString(json["tool_name"]) ?? "tool"
			if enableDebugLogging {
				diagnostics("[GeminiAgent] Tool result event: \(identifier)")
			}
			var summary = GeminiEventParser.stringify(json["output"]) ?? ""
			if summary.isEmpty, let status = json["status"] as? String {
				summary = "status: \(status)"
			}
			return .toolResult(name: identifier, result: summary)
		case "result":
			let status = (json["status"] as? String)?.lowercased()
			if enableDebugLogging {
				diagnostics("[GeminiAgent] Result event - status: \(status ?? "nil")")
			}
			let sessionID = GeminiEventParser.extractString(json["session_id"]) ?? GeminiEventParser.extractString(json["sessionId"]) ?? providerSessionID
			if let sessionID, !sessionID.isEmpty {
				providerSessionID = sessionID
			}
			if status == "success" {
				let usage = GeminiEventParser.parseUsage(json["stats"] as? [String: Any])
				if enableDebugLogging {
					diagnostics("[GeminiAgent] Completion event - tokens: \(usage?.inputTokens ?? 0)/\(usage?.outputTokens ?? 0)")
				}
				return .completion(inputTokens: usage?.inputTokens, outputTokens: usage?.outputTokens, providerSessionID: providerSessionID)
			} else if status == "error" {
				let message = GeminiEventParser.extractErrorMessage(json["error"]) ?? "Gemini CLI reported an error."
				if enableDebugLogging {
					diagnostics("[GeminiAgent] Error in result: \(message)")
				}
				throw GeminiHeadlessParserError.runtime(message)
			}
			return nil
		default:
			if enableDebugLogging {
				diagnostics("[GeminiAgent] WARNING: Unknown event type: \(type)")
			}
			return nil
		}
	}

	public func extractCLIErrorDetail(fromStdout data: Data) -> String? {
		guard !data.isEmpty else { return nil }
		if enableDebugLogging {
			if let rawPreview = String(data: data.prefix(500), encoding: .utf8) {
				diagnostics("[GeminiAgent] extractCLIErrorDetail - stdout preview: \(rawPreview)")
			}
		}
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

		for slice in lines {
			let trimmedData = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(trimmedData) else { continue }
			if let envelope = try? decoder.decode(GeminiResultEnvelope.self, from: trimmed) {
				if let message = envelope.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
					return message
				}
				if let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
					return message
				}
			}
			if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
				// Check for error object with code
				if let errorDict = json["error"] as? [String: Any] {
					let code = errorDict["code"] as? Int
					let message = (errorDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

					// Check for 404 "not found" error - likely preview features not enabled or model unavailable
					// The message may contain stringified JSON with the actual 404 error, or "[object Object]"
					if code == 404 || message.lowercased().contains("not found") || message.contains("404") {
						if enableDebugLogging {
							diagnostics("[GeminiAgent] Detected 404 error - code: \(code ?? -1), message contains 'not found' or '404'")
						}
						return "Model not found (404). For Gemini 3 preview models, enable 'Preview features' in Gemini CLI settings. Run `gemini` interactively and type /settings to configure. For other models, check that your Gemini account has access to the selected model."
					}

					// Also check if the message contains stringified JSON with error info
					if message.contains("[object Object]") || (message.isEmpty && code == 1) {
						// CLI failed to serialize error - check raw data for 404
						if let rawString = String(data: data, encoding: .utf8),
						   rawString.contains("404") || rawString.lowercased().contains("not found") {
							return "Model not found (404). For Gemini 3 preview models, enable 'Preview features' in Gemini CLI settings. Run `gemini` interactively and type /settings to configure. For other models, check that your Gemini account has access to the selected model."
						}
					}

					if !message.isEmpty && message != "[object Object]" {
						return message
					}
				}

				if let type = json["type"] as? String,
					type == "result",
					let status = (json["status"] as? String)?.lowercased(),
					status == "error",
					let message = GeminiEventParser.extractErrorMessage(json["error"])?.trimmingCharacters(in: .whitespacesAndNewlines),
					!message.isEmpty {
					return message
				}
				if let message = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
					!message.isEmpty {
					return message
				}
			}
		}

		for slice in lines {
			let trimmedData = Data(slice)
			guard let trimmed = trimmedASCIIWhitespace(trimmedData) else { continue }
			if let plain = String(data: trimmed, encoding: .utf8) {
				let cleaned = plain.trimmingCharacters(in: .whitespacesAndNewlines)
				if !cleaned.isEmpty && !cleaned.hasPrefix("{") && !cleaned.hasPrefix("[") {
					return cleaned
				}
			}
		}
		return nil
	}
}
private struct TokenUsage { let inputTokens: Int; let outputTokens: Int }
private enum GeminiEventParser {
	static func extractString(_ value: Any?) -> String? {
		switch value {
		case let string as String:
			return string
		case let dict as [String: Any]:
			if let text = dict["text"] as? String {
				return text
			}
			if let delta = dict["delta"] as? String {
				return delta
			}
			return nil
		case let array as [Any]:
			let components = array.compactMap { extractString($0) }
			guard !components.isEmpty else { return nil }
			return components.joined()
		default:
			return nil
		}
	}

	static func extractDictionary(_ value: Any?) -> [String: Any] {
		value as? [String: Any] ?? [:]
	}

	static func stringify(_ value: Any?) -> String? {
		switch value {
		case nil:
			return nil
		case let string as String:
			return string
		case let number as NSNumber:
			return number.stringValue
		case let dict as [String: Any]:
			return serializeJSON(dict)
		case let array as [Any]:
			return serializeJSON(array)
		default:
			return String(describing: value!)
		}
	}

	static func parseUsage(_ stats: [String: Any]?) -> TokenUsage? {
		guard let stats else { return nil }
		let input = numberToInt(stats["input_tokens"])
			?? numberToInt(stats["prompt_tokens"])
			?? numberToInt(stats["promptTokens"])
		let output = numberToInt(stats["output_tokens"])
			?? numberToInt(stats["completion_tokens"])
			?? numberToInt(stats["completionTokens"])
		if let input, let output {
			return TokenUsage(inputTokens: input, outputTokens: output)
		}
		return nil
	}

	static func extractErrorMessage(_ value: Any?) -> String? {
		if let string = value as? String {
			return string
		}
		if let dict = value as? [String: Any] {
			if let message = dict["message"] as? String, !message.isEmpty {
				return message
			}
			if let detail = dict["details"] as? String, !detail.isEmpty {
				return detail
			}
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
		case let number as NSNumber:
			return number.intValue
		default:
			return nil
		}
	}

	private static func serializeJSON(_ object: Any) -> String? {
		guard JSONSerialization.isValidJSONObject(object) else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

private struct GeminiResultEnvelope: Decodable {
	struct ErrorInfo: Decodable {
		let message: String?
	}

	let type: String?
	let status: String?
	let error: ErrorInfo?
	let message: String?
}
