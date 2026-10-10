import XCTest
import AIClientKit
import AgentClaudeContent

final class ClaudeContentSuppressionTests: XCTestCase {
	func testShouldSuppressUserFacingStreamResultForKnownClaudeAbortArtifact() {
		let result = AIStreamResult(
			type: "error",
			text: """
			SyntaxError: JSON Parse error: Unrecognized token '/'
			at <parse> (:0)
			at parse (unknown)
			at <anonymous> (/$bunfs/root/src/entrypoints/cli.js:98:1134)
			"""
		)

		XCTAssertTrue(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressUserFacingStreamResultForClaudeInternalStopReasonDiagnostic() {
		let result = AIStreamResult(
			type: "error",
			text: "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"
		)

		XCTAssertTrue(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressUserFacingStreamResultForGenericClaudeDiagnosticError() {
		let result = AIStreamResult(
			type: "error",
			text: "Internal diagnostic: provider emitted non-user-facing trace output"
		)

		XCTAssertTrue(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressUserFacingStreamResultForLegitimateDiagnosticError() {
		let result = AIStreamResult(
			type: "error",
			text: "Error: diagnostic upload failed for the selected workspace"
		)

		XCTAssertFalse(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressUserFacingStreamResultForLegitimateClaudeError() {
		let result = AIStreamResult(
			type: "error",
			text: "Error: failed to parse config: JSON Parse error at line 4"
		)

		XCTAssertFalse(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	// MARK: - Background Task Notification Suppression

	func testShouldSuppressTaskNotificationSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Task update — blj2xgod6 — failed — Background command \"Run transcript services tests via daemon\" failed with exit code 1"
		)

		XCTAssertTrue(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldSuppressTaskStartedSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Task started — abc123 — Running unit tests"
		)

		XCTAssertTrue(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

	func testShouldNotSuppressLegitimateSystemMessage() {
		let result = AIStreamResult(
			type: "system",
			text: "Context compacted — trigger: auto — at ~180000 tokens"
		)

		XCTAssertFalse(ClaudeContentFrame.shouldSuppressUserFacingStreamResult(result))
	}

}
