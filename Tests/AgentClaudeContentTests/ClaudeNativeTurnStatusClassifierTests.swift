import XCTest
import AgentClaudeContent
import AgentClaudeProtocol
import AgentClaudeEvents

final class ClaudeNativeTurnStatusClassifierTests: XCTestCase {
	private func classify(_ payload: [String: Any], hint: String? = nil) throws -> ClaudeNativeTurnStatus {
		try ClaudeNativeTurnStatusClassifier.classify(ClaudeProtocolJSONObject(object: payload), stopReasonHint: hint)
	}
	func testExecutionErrorsRemainFailed() throws {
		XCTAssertEqual(try classify(["type": "result", "subtype": "error_during_execution", "is_error": false, "errors": ["SyntaxError: JSON Parse error"]]), .failed)
	}
	func testAbortedExecutionErrorRemainsCancelled() throws {
		XCTAssertEqual(try classify(["type": "result", "subtype": "error_during_execution", "is_error": false, "errors": ["Error: Request was aborted."]]), .cancelled)
	}
	func testCancelledSignalsTakePriorityAcrossWireFields() throws {
		for signal in [" interrupted ", "CANCELLED", "aborted", "request was aborted"] {
			XCTAssertEqual(try classify(["subtype": signal, "is_error": true]), .cancelled)
			XCTAssertEqual(try classify(["stop_reason": signal, "subtype": "error"]), .cancelled)
			XCTAssertEqual(try classify(["event": ["delta": ["stop_reason": signal]], "is_error": true]), .cancelled)
			XCTAssertEqual(try classify(["errors": [["message": signal]], "is_error": true]), .cancelled)
			XCTAssertEqual(try classify(["is_error": true], hint: signal), .cancelled)
		}
	}
	func testErrorObjectsPreserveMessagePriorityAndIgnoreMalformedEntries() throws {
		XCTAssertEqual(try classify(["errors": [["message": "ok", "error": "cancelled"]]]), .failed)
		XCTAssertEqual(try classify(["errors": [["error": "cancelled"]]]), .cancelled)
		XCTAssertEqual(try classify(["errors": [["message": " ", "error": "cancelled"], 1, false, " "]]), .completed)
		XCTAssertEqual(try classify(["errors": "failure"]), .completed)
	}
	func testErrorFlagSubtypeOrAnyNonblankErrorFails() throws {
		for payload: [String: Any] in [["is_error": true], ["subtype": " ERROR_DURING_EXECUTION "], ["errors": ["failure"]], ["errors": [["error": " failure "]]]] {
			XCTAssertEqual(try classify(payload), .failed)
		}
	}
	func testSuccessUnknownAndBlankFieldsRemainCompleted() throws {
		XCTAssertEqual(try classify([:]), .completed)
		XCTAssertEqual(try classify(["subtype": "success", "stop_reason": "end_turn", "is_error": false, "errors": [" ", ["message": ""]]]), .completed)
		XCTAssertEqual(try classify(["event": ["delta": ["stop_reason": "end_turn"]]], hint: " "), .completed)
	}
}
