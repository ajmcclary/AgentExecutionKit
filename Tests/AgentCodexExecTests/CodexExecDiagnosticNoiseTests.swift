import XCTest
import AgentCodexExec

final class CodexExecDiagnosticNoiseTests: XCTestCase {

	// MARK: - Should suppress (diagnostic noise)

	func testSuppressesGoStructuredLogWithTimestamp() {
		let message = "2026-04-09T10:51:37.031 37819/E INFO session_heartbeat_scheduler: heartbeat sent successfully"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesGoTimestampWithDateOnly() {
		let message = "2026-04-09 10:51:37 DEBUG transport initialized"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesGoSourceFileReference() {
		let message = "process_terminal(1) middleware.go:3 codex-openai(?) v1.0.1"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesProcessTerminal() {
		let message = "process_terminal exited with status 0"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesSessionHeartbeat() {
		let message = "session_heartbeat: connection alive"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesHeartbeatScheduler() {
		let message = "heartbeat_scheduler tick interval=30s"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesModelClientDiagnostic() {
		let message = "model_client_stream_response: status=200 tokens=1500"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesStreamResponseDiagnostic() {
		let message = "stream_response completed in 2.3s"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesJSONRPCMessage() {
		let message = #"{"jsonrpc":"2.0","method":"tools/list","id":1}"#
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesJSONProtocolWithMethodOnly() {
		let message = #"{"method":"initialize","params":{"capabilities":{}}}"#
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesJSONProtocolWithResult() {
		let message = #"{"id":42,"result":{"tools":["read_file"]}}"#
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesHTTPHeaderDiagnostic() {
		let message = "x-request-id: abc123-def456"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesRateLimitHeader() {
		let message = "x-ratelimit-remaining: 45"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesContentTypeHeader() {
		let message = "content-type: application/json"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesCodexOpenAIReference() {
		let message = "codex-openai proxy initialized on port 8080"
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testSuppressesEmptyMessage() {
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress(""))
	}

	func testSuppressesWhitespaceOnlyMessage() {
		XCTAssertTrue(CodexExecDiagnosticNoiseFilter.shouldSuppress("   \n\t  "))
	}

	// MARK: - Should NOT suppress (legitimate messages)

	func testDoesNotSuppressAuthenticationError() {
		let message = "Error: not authenticated. Run `codex login` first."
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressCommandNotFound() {
		let message = "codex: command not found"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressRateLimitError() {
		let message = "Error: rate limit exceeded. Please wait and try again."
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressModelNotFoundError() {
		let message = "Error: model 'gpt-5' not found or not available"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressPermissionError() {
		let message = "Permission denied: cannot read /etc/config"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressGenericPlainTextError() {
		let message = "Fatal: unable to connect to API endpoint"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressUserFacingStatusMessage() {
		let message = "Requested model gpt-5.2 is unavailable. Retrying with gpt-5.1."
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	// MARK: - JSON with error/message fields must remain visible

	func testDoesNotSuppressJSONWithErrorField() {
		let message = #"{"error":"not authenticated"}"#
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressJSONWithMessageField() {
		let message = #"{"message":"model not found"}"#
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressJSONWithErrorAndJSONRPC() {
		// An error response in JSON-RPC format should still be visible
		let message = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"invalid request"}}"#
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	// MARK: - Non-JSON objects should not be blindly suppressed

	func testDoesNotSuppressArbitraryJSONWithoutProtocolFields() {
		// Generic JSON without protocol fields should pass through
		let message = #"{"status":"failed","reason":"timeout"}"#
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	// MARK: - Legitimate messages with formerly-overbroad patterns

	func testDoesNotSuppressMiddlewareInLegitimateError() {
		let message = "middleware init failed: permission denied"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}

	func testDoesNotSuppressOpenAICompatibleInError() {
		let message = "OpenAI-compatible endpoint unavailable"
		XCTAssertFalse(CodexExecDiagnosticNoiseFilter.shouldSuppress(message))
	}
}
