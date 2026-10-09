import XCTest
import Foundation
import AgentClaudeProtocol
import AIClientKit
import ClaudeRuntimeKit

final class ClaudeNativeProtocolTests: XCTestCase {
	func testTypedControlRequestRetainsLargeNumbersAndUnknownFieldsAcrossTasks() async throws {
		let line = Data(#"{"type":"control_request","request_id":"r","request":{"subtype":"future","number":9007199254740993,"unknown":{"flag":true}}}"#.utf8)
		let value = try XCTUnwrap(ClaudeNativeProtocolCodec.decodeLine(line))
		let number = try await Task { () throws -> String? in
			guard case .controlRequest(let request) = value else { return nil }
			return (try request.request.dictionary()["number"] as? NSNumber)?.stringValue
		}.value
		XCTAssertEqual(number, "9007199254740993")
		guard case .controlRequest(let request) = value else { return XCTFail("Expected request") }
		XCTAssertEqual(request.requestID, "r")
		XCTAssertEqual(request.subtype, "future")
		let encoded = try ClaudeNativeProtocolCodec.encodeControlRequest(requestID: request.requestID, request: request.request)
		let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
		XCTAssertEqual((((object["request"] as? [String: Any])?["unknown"]) as? [String: Bool])?["flag"], true)
	}

	func testControlResponseKeepsPendingPermissionsAndError() throws {
		let line = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"r","error":"denied","pending_permission_requests":[{"request_id":"p","unknown":true}]}}"#.utf8)
		guard case .controlResponse(let response)? = try ClaudeNativeProtocolCodec.decodeLine(line) else { return XCTFail("Expected response") }
		XCTAssertEqual(response.error, "denied")
		XCTAssertNil(response.response)
		XCTAssertEqual(try response.pendingPermissionRequests.first?.dictionary()["request_id"] as? String, "p")
		XCTAssertEqual(try response.pendingPermissionRequests.first?.dictionary()["unknown"] as? Bool, true)
	}

	func testBlankKeepAliveUnknownAndCancelledMessagesKeepTheirClassification() throws {
		XCTAssertNil(try ClaudeNativeProtocolCodec.decodeLine(Data(" \n\t".utf8)))
		guard case .keepAlive? = try ClaudeNativeProtocolCodec.decodeLine(Data(#"{"type":"keep_alive"}"#.utf8)) else { return XCTFail("Expected keepalive") }
		guard case .controlCancelRequest(let id)? = try ClaudeNativeProtocolCodec.decodeLine(Data(#"{"type":"control_cancel_request","request_id":"p"}"#.utf8)) else { return XCTFail("Expected cancellation") }
		XCTAssertEqual(id, "p")
		guard case .streamPayload(let payload)? = try ClaudeNativeProtocolCodec.decodeLine(Data(#"{"type":"future","unknown":[null,true]}"#.utf8)) else { return XCTFail("Expected stream payload") }
		XCTAssertEqual((try payload.dictionary()["unknown"] as? [Any])?.count, 2)
	}

	func testMalformedControlAndNonObjectPayloadsAreRejectedAndRawControlsRecover() throws {
		XCTAssertThrowsError(try ClaudeNativeProtocolCodec.decodeLine(Data(#"{"type":"control_request","request":{}}"#.utf8))) { error in
			XCTAssertEqual(error as? ClaudeNativeProtocolCodec.CodecError, .unsupportedPayload)
		}
		XCTAssertThrowsError(try ClaudeProtocolJSONObject(data: Data("[]".utf8)))
		XCTAssertThrowsError(try ClaudeNativeProtocolCodec.decodeLine(Data("bad".utf8)))
		guard case .streamPayload(let payload)? = try ClaudeNativeProtocolCodec.decodeLine(Data("{\"type\":\"future\",\"text\":\"a\nb\tc\"}".utf8)) else { return XCTFail("Expected recovered payload") }
		XCTAssertEqual(try payload.dictionary()["text"] as? String, "a\nb\tc")
	}

	func testEncoderOmitsEmptyResponseAndPreservesUserNullParent() throws {
		let empty = try ClaudeProtocolJSONObject(data: Data("{}".utf8))
		let success = try ClaudeNativeProtocolCodec.encodeControlResponseSuccess(requestID: "r", response: empty)
		let successObject = try JSONSerialization.jsonObject(with: success) as! [String: Any]
		XCTAssertNil((successObject["response"] as? [String: Any])?["response"])
		let error = try ClaudeNativeProtocolCodec.encodeControlResponseError(requestID: "r", error: "denied")
		let errorObject = try JSONSerialization.jsonObject(with: error) as! [String: Any]
		XCTAssertEqual((errorObject["response"] as? [String: Any])?["error"] as? String, "denied")
		let user = try ClaudeNativeProtocolCodec.encodeUserMessage(text: "hello", sessionID: "")
		let userObject = try JSONSerialization.jsonObject(with: user) as! [String: Any]
		XCTAssertNil(userObject["session_id"])
		XCTAssertTrue(userObject["parent_tool_use_id"] is NSNull)
	}

	func testToolStatusOwnershipIsInjectedAndIsolatedBetweenHosts() {
		let frame = Data(#"{"type":"tool_result","tool_name":"host-tool","is_error":true,"tool_result":{"status":"failed"}}"#.utf8)
		var external = ClaudeNativeEventTranslator(policy: .init(isExternallyTrackedTool: { $0 == "host-tool" }, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }))
		var internalHost = ClaudeNativeEventTranslator(policy: .init(isExternallyTrackedTool: { _ in false }, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }))
		XCTAssertNil(external.translate(frame).results.first?.toolIsError)
		XCTAssertEqual(internalHost.translate(frame).results.first?.toolIsError, true)
	}

	func testTranslationBatchTransfersAllLanesWithoutReclassifyingDiagnostics() async throws {
		var translator = ClaudeNativeEventTranslator()
		let batch = translator.translate(Data(#"{"type":"future","api_key":"fixture-secret"}"#.utf8))
		let counts = await Task { [batch] in
			[batch.results.count, batch.normalizedEvents.count, batch.diagnostics.count, batch.envelope.rawBytes.count]
		}.value
		XCTAssertEqual(Array(counts.prefix(3)), [0, 0, 1])
		XCTAssertFalse(String(describing: batch.diagnostics.first?.redactedPayload).contains("fixture-secret"))
		XCTAssertTrue(ClaudeNativeResultProjection.project(batch.normalizedEvents).isEmpty)
	}
}
