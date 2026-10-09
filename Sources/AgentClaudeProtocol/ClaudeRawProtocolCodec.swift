import Foundation
import ProcessStreamFraming

enum ClaudeRawProtocolCodec {
	enum InboundMessage {
		case streamPayload([String: Any])
		case controlRequest(ControlRequest)
		case controlResponse(ControlResponse)
		case controlCancelRequest(requestID: String)
		case keepAlive
	}

	struct ControlRequest {
		let requestID: String
		let request: [String: Any]
		let subtype: String
	}

	struct ControlResponse {
		let requestID: String
		let subtype: String
		let response: [String: Any]?
		let error: String?
		let pendingPermissionRequests: [[String: Any]]
	}

	enum CodecError: Error {
		case invalidJSON
		case unsupportedPayload
	}

	static func decodeLine(_ lineData: Data) throws -> InboundMessage? {
		guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else {
			return nil
		}
		let object = try parseJSONObject(from: trimmed)

		let type = (object["type"] as? String) ?? ""
		switch type {
		case "control_request":
			guard let requestID = object["request_id"] as? String,
				let request = object["request"] as? [String: Any]
			else {
				throw CodecError.unsupportedPayload
			}
			let subtype = (request["subtype"] as? String) ?? ""
			return .controlRequest(
				ControlRequest(
					requestID: requestID,
					request: request,
					subtype: subtype
				)
			)
		case "control_response":
			guard let envelope = object["response"] as? [String: Any],
				let requestID = envelope["request_id"] as? String,
				let subtype = envelope["subtype"] as? String
			else {
				throw CodecError.unsupportedPayload
			}
			let responseObject = envelope["response"] as? [String: Any]
			let error = envelope["error"] as? String
			let pendingPermissionRequests = envelope["pending_permission_requests"] as? [[String: Any]] ?? []
			return .controlResponse(
				ControlResponse(
					requestID: requestID,
					subtype: subtype,
					response: responseObject,
					error: error,
					pendingPermissionRequests: pendingPermissionRequests
				)
			)
		case "control_cancel_request":
			guard let requestID = object["request_id"] as? String else {
				throw CodecError.unsupportedPayload
			}
			return .controlCancelRequest(requestID: requestID)
		case "keep_alive":
			return .keepAlive
		default:
			return .streamPayload(object)
		}
	}

	private static func parseJSONObject(from data: Data) throws -> [String: Any] {
		func decodeObject(from data: Data) throws -> [String: Any] {
			let rawObject = try JSONSerialization.jsonObject(with: data)
			guard let object = rawObject as? [String: Any] else {
				throw CodecError.invalidJSON
			}
			return object
		}

		do {
			return try decodeObject(from: data)
		} catch {
			guard let text = String(data: data, encoding: .utf8),
				let sanitized = sanitizeJSONControlCharactersInStrings(in: text),
				let sanitizedData = sanitized.data(using: .utf8)
			else {
				throw CodecError.invalidJSON
			}
			do {
				return try decodeObject(from: sanitizedData)
			} catch {
				throw CodecError.invalidJSON
			}
		}
	}

	private static func sanitizeJSONControlCharactersInStrings(in raw: String) -> String? {
		guard !raw.isEmpty else { return nil }
		var output = String()
		output.reserveCapacity(raw.count + 8)
		var inString = false
		var isEscaping = false
		var didSanitize = false

		for character in raw {
			if inString {
				if isEscaping {
					output.append(character)
					isEscaping = false
					continue
				}
				switch character {
				case "\\":
					output.append(character)
					isEscaping = true
				case "\"":
					output.append(character)
					inString = false
				case "\n":
					output.append("\\n")
					didSanitize = true
				case "\r":
					output.append("\\r")
					didSanitize = true
				case "\t":
					output.append("\\t")
					didSanitize = true
				default:
					output.append(character)
				}
			} else {
				output.append(character)
				if character == "\"" {
					inString = true
				}
			}
		}

		guard didSanitize else { return nil }
		return output
	}

	static func encodeControlRequest(requestID: String, request: [String: Any]) throws -> Data {
		let payload: [String: Any] = [
			"type": "control_request",
			"request_id": requestID,
			"request": request
		]
		return try JSONSerialization.data(withJSONObject: payload, options: [])
	}

	static func encodeControlResponseSuccess(requestID: String, response: [String: Any]? = nil) throws -> Data {
		var envelope: [String: Any] = [
			"subtype": "success",
			"request_id": requestID
		]
		if let response, !response.isEmpty {
			envelope["response"] = response
		}
		let payload: [String: Any] = [
			"type": "control_response",
			"response": envelope
		]
		return try JSONSerialization.data(withJSONObject: payload, options: [])
	}

	static func encodeControlResponseError(requestID: String, error: String) throws -> Data {
		let payload: [String: Any] = [
			"type": "control_response",
			"response": [
				"subtype": "error",
				"request_id": requestID,
				"error": error
			]
		]
		return try JSONSerialization.data(withJSONObject: payload, options: [])
	}

	static func encodeUserMessage(text: String, sessionID: String?) throws -> Data {
		var payload: [String: Any] = [
			"type": "user",
			"message": [
				"role": "user",
				"content": [
					[
						"type": "text",
						"text": text
					]
				]
			],
			"parent_tool_use_id": NSNull()
		]
		if let sessionID, !sessionID.isEmpty {
			payload["session_id"] = sessionID
		}
		return try JSONSerialization.data(withJSONObject: payload, options: [])
	}
}
