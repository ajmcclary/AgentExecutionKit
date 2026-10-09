import XCTest
@testable import AgentClaudeProtocol
import ClaudeRuntimeKit
import AIClientKit

/// Slice 1 behavior tests for `ClaudeSDKNDJSONTranslator` (flipped from the
/// original pre-hardening characterization).
///
/// These pin the POST-Slice-1 two-lane behavior: the semantic `results` lane is
/// byte-identical to before (no tool/content result added or removed), while
/// previously-silent drops now surface on the redacted `diagnostics` lane. Each
/// assertion below is the deliberate flip of a step-1 characterization test, so
/// the behavior change is visible in the diff.
final class ClaudeSDKNDJSONTranslatorSlice1CharacterizationTests: XCTestCase {
	private func translate(
		_ line: String,
		with translator: inout ClaudeSDKNDJSONTranslator
	) -> ClaudeTranslationBatch {
		translator.translate(Data(line.utf8))
	}

	// MARK: - Unknown events now become redacted diagnostics

	func testUnknownTopLevelTypeIsPreservedAsDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate(#"{"type":"totally_new_event","payload":{"foo":"bar"}}"#, with: &translator)

		XCTAssertTrue(batch.results.isEmpty, "results lane unchanged")
		XCTAssertEqual(batch.diagnostics.map(\.kind), [.unknownEvent])
	}

	func testContentBlockStartIsHandledWithoutDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate(
			#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash"}}}"#,
			with: &translator)

		// content_block_start is now a known event (begins assembly): no results,
		// no diagnostic.
		XCTAssertTrue(batch.results.isEmpty)
		XCTAssertTrue(batch.diagnostics.isEmpty)
	}

	func testGenuinelyUnknownStreamEventBecomesDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate(
			#"{"type":"stream_event","event":{"type":"mystery_stream_event","data":"x"}}"#,
			with: &translator)

		XCTAssertTrue(batch.results.isEmpty)
		XCTAssertEqual(batch.diagnostics.map(\.kind), [.malformedKnownEvent])
	}

	func testUnknownAssistantContentBlockDiagnosedButSiblingTextSurvives() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate(
			#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"},{"type":"mystery_block","data":"x"}]}}"#,
			with: &translator)

		XCTAssertEqual(batch.results.map(\.type), ["content"])
		XCTAssertEqual(batch.results.first?.text, "hello")
		XCTAssertEqual(batch.diagnostics.map(\.kind), [.malformedKnownEvent])
	}

	// MARK: - Fragmented tool input is now assembled

	func testValidStreamedToolInputAssemblesWithoutResultsOrDiagnostics() {
		var translator = ClaudeSDKNDJSONTranslator()
		_ = translate(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#, with: &translator)
		_ = translate(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash"}}}"#, with: &translator)
		let delta = translate(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}}"#, with: &translator)
		let stop = translate(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#, with: &translator)

		// Slice 1: assembly happens internally; no duplicate tool_call is emitted
		// (the complete assistant message stays authoritative) and no diagnostic.
		XCTAssertTrue(delta.results.isEmpty)
		XCTAssertTrue(delta.diagnostics.isEmpty)
		XCTAssertTrue(stop.results.isEmpty)
		XCTAssertTrue(stop.diagnostics.isEmpty)
	}

	func testMalformedStreamedToolInputBecomesDiagnosticAtBlockStop() {
		var translator = ClaudeSDKNDJSONTranslator()
		_ = translate(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#, with: &translator)
		_ = translate(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Bash"}}}"#, with: &translator)
		_ = translate(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}}"#, with: &translator)
		_ = translate(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"not-json"}}}"#, with: &translator)
		let stop = translate(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#, with: &translator)

		XCTAssertTrue(stop.results.isEmpty)
		XCTAssertEqual(stop.diagnostics.map(\.kind), [.malformedToolInput])
	}

	// MARK: - Malformed input

	func testNonJSONLineBecomesMalformedLineDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate("this is not json", with: &translator)

		XCTAssertTrue(batch.results.isEmpty)
		XCTAssertEqual(batch.diagnostics.map(\.kind), [.malformedLine])
	}

	func testBlankLineProducesNoResultsAndNoDiagnostics() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate("   ", with: &translator)

		XCTAssertTrue(batch.results.isEmpty)
		XCTAssertTrue(batch.diagnostics.isEmpty)
	}

	func testMalformedToolUseInputKeepsBestEffortCallAndAddsDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let batch = translate(
			#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":"not-an-object"}]}}"#,
			with: &translator)

		// Results lane unchanged: still a best-effort tool_call with empty args.
		XCTAssertEqual(batch.results.map(\.type), ["tool_call"])
		XCTAssertEqual(batch.results.first?.toolName, "Bash")
		XCTAssertNil(batch.results.first?.toolArgsJSON)
		// But the lost input is now recorded.
		XCTAssertEqual(batch.diagnostics.map(\.kind), [.malformedKnownEvent])
	}

	// MARK: - Interleaved text deltas (unchanged)

	func testInterleavedTextDeltasStillEmitContentUnchanged() {
		var translator = ClaudeSDKNDJSONTranslator()
		let block0 = translate(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}}"#, with: &translator)
		let block1 = translate(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"B"}}}"#, with: &translator)

		XCTAssertEqual(block0.results.map(\.type), ["content"])
		XCTAssertEqual(block0.results.first?.text, "A")
		XCTAssertTrue(block0.diagnostics.isEmpty)
		XCTAssertEqual(block1.results.first?.text, "B")
		XCTAssertTrue(block1.diagnostics.isEmpty)
	}

	// MARK: - Redaction

	func testUnknownEventWithSensitiveFieldsIsRedactedInDiagnostic() {
		var translator = ClaudeSDKNDJSONTranslator()
		let secret = "sk-ant-SUPERSECRET"
		let batch = translate(
			#"{"type":"secret_event","api_key":"\#(secret)","authorization":"Bearer abc123"}"#,
			with: &translator)

		XCTAssertTrue(batch.results.isEmpty)
		let diagnostic = try? XCTUnwrap(batch.diagnostics.first)
		XCTAssertEqual(diagnostic?.kind, .unknownEvent)
		XCTAssertFalse(diagnostic?.summary.contains(secret) ?? true)
		XCTAssertFalse(String(describing: diagnostic?.redactedPayload).contains(secret))
		XCTAssertEqual(diagnostic?.redactedPayload?["api_key"] as? String, ClaudeCredentialRedactor.placeholder)
	}
}
