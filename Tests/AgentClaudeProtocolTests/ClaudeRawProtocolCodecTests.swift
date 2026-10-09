import XCTest
@testable import AgentClaudeProtocol

final class ClaudeRawProtocolCodecTests: XCTestCase {
	private func jsonObject(from data: Data) throws -> [String: Any] {
		let object = try JSONSerialization.jsonObject(with: data)
		return try XCTUnwrap(object as? [String: Any])
	}

	func testDecodeLineReturnsNilForWhitespaceOnlyPayload() throws {
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data("  \n\t ".utf8))
		XCTAssertNil(decoded)
	}

	func testDecodeLineParsesControlRequest() throws {
		let line = #"{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .controlRequest(let request)? = decoded else {
			return XCTFail("Expected control request")
		}
		XCTAssertEqual(request.requestID, "req-1")
		XCTAssertEqual(request.subtype, "can_use_tool")
		XCTAssertEqual(request.request["tool_name"] as? String, "Bash")
	}

	func testDecodeLineParsesControlResponseWithPendingPermissions() throws {
		let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"req-1","error":"denied","pending_permission_requests":[{"request_id":"perm-1","request":{"subtype":"can_use_tool"}}]}}"#
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .controlResponse(let response)? = decoded else {
			return XCTFail("Expected control response")
		}
		XCTAssertEqual(response.requestID, "req-1")
		XCTAssertEqual(response.subtype, "error")
		XCTAssertEqual(response.error, "denied")
		XCTAssertEqual(response.pendingPermissionRequests.count, 1)
		XCTAssertEqual(response.pendingPermissionRequests.first?["request_id"] as? String, "perm-1")
	}

	func testDecodeLineParsesControlCancelRequest() throws {
		let line = #"{"type":"control_cancel_request","request_id":"perm-1"}"#
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .controlCancelRequest(let requestID)? = decoded else {
			return XCTFail("Expected control cancel request")
		}
		XCTAssertEqual(requestID, "perm-1")
	}

	func testDecodeLineThrowsInvalidJSONForNonDictionaryPayload() {
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data("[]".utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.invalidJSON = error else {
				return XCTFail("Expected invalidJSON error")
			}
		}
	}

	func testDecodeLineThrowsInvalidJSONForMalformedPayload() {
		let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"unterminated"}]"#
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.invalidJSON = error else {
				return XCTFail("Expected invalidJSON error for malformed JSON payload")
			}
		}
	}

	func testDecodeLineRecoversRawControlCharactersInsideJSONStringValues() throws {
		let line = """
		{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line one
		line two"}]}}
		"""
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .streamPayload(let payload)? = decoded else {
			return XCTFail("Expected stream payload")
		}
		let message = try XCTUnwrap(payload["message"] as? [String: Any])
		let content = try XCTUnwrap(message["content"] as? [[String: Any]])
		let first = try XCTUnwrap(content.first)
		XCTAssertEqual(first["text"] as? String, "line one\nline two")
	}

	func testDecodeLineTreatsUnknownTypeAsStreamPayload() throws {
		let line = #"{"type":"future_event","value":42}"#
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .streamPayload(let payload)? = decoded else {
			return XCTFail("Expected stream payload")
		}
		XCTAssertEqual(payload["type"] as? String, "future_event")
		XCTAssertEqual(payload["value"] as? Int, 42)
	}

	func testDecodeLineThrowsUnsupportedPayloadWhenControlRequestMissingRequestID() {
		let line = #"{"type":"control_request","request":{"subtype":"can_use_tool"}}"#
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.unsupportedPayload = error else {
				return XCTFail("Expected unsupportedPayload error")
			}
		}
	}

	func testDecodeLineThrowsUnsupportedPayloadWhenControlCancelMissingRequestID() {
		let line = #"{"type":"control_cancel_request"}"#
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.unsupportedPayload = error else {
				return XCTFail("Expected unsupportedPayload error")
			}
		}
	}

	func testDecodeLineThrowsUnsupportedPayloadWhenControlResponseMissingSubtypeOrRequestID() {
		let missingSubtype = #"{"type":"control_response","response":{"request_id":"req-1"}}"#
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data(missingSubtype.utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.unsupportedPayload = error else {
				return XCTFail("Expected unsupportedPayload for missing subtype")
			}
		}

		let missingRequestID = #"{"type":"control_response","response":{"subtype":"success"}}"#
		XCTAssertThrowsError(try ClaudeRawProtocolCodec.decodeLine(Data(missingRequestID.utf8))) { error in
			guard case ClaudeRawProtocolCodec.CodecError.unsupportedPayload = error else {
				return XCTFail("Expected unsupportedPayload for missing request_id")
			}
		}
	}

	func testDecodeLineParsesControlResponseErrorWithoutPendingPermissionsAsEmptyList() throws {
		let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"req-99","error":"nope"}}"#
		let decoded = try ClaudeRawProtocolCodec.decodeLine(Data(line.utf8))

		guard case .controlResponse(let response)? = decoded else {
			return XCTFail("Expected control response")
		}
		XCTAssertEqual(response.requestID, "req-99")
		XCTAssertEqual(response.subtype, "error")
		XCTAssertEqual(response.error, "nope")
		XCTAssertTrue(response.pendingPermissionRequests.isEmpty)
	}

	func testEncodeUserMessageOmitsSessionIDWhenEmpty() throws {
		let encoded = try ClaudeRawProtocolCodec.encodeUserMessage(text: "hello", sessionID: "")
		let object = try jsonObject(from: encoded)

		XCTAssertNil(object["session_id"])
		let message = try XCTUnwrap(object["message"] as? [String: Any])
		let content = try XCTUnwrap(message["content"] as? [[String: Any]])
		let firstBlock = try XCTUnwrap(content.first)
		XCTAssertEqual(firstBlock["type"] as? String, "text")
		XCTAssertEqual(firstBlock["text"] as? String, "hello")
		XCTAssertTrue(object["parent_tool_use_id"] is NSNull)
	}

	func testEncodeUserMessageIncludesSessionIDWhenProvided() throws {
		let encoded = try ClaudeRawProtocolCodec.encodeUserMessage(text: "hello", sessionID: "session-123")
		let object = try jsonObject(from: encoded)

		XCTAssertEqual(object["session_id"] as? String, "session-123")
	}
}
