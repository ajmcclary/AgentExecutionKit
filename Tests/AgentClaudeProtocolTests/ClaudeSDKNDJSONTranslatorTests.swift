import XCTest
@testable import AgentClaudeProtocol
import ClaudeRuntimeKit
import AIClientKit

final class ClaudeSDKNDJSONTranslatorTests: XCTestCase {

	private func parse(
		_ line: String,
		with translator: inout ClaudeSDKNDJSONTranslator
	) -> [AIStreamResult] {
		translator.translate(Data(line.utf8)).results
	}

	func testParseResultErrorEmitsErrorAndMessageStop() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","is_error":true,"error":"boom","usage":{"input_tokens":3,"output_tokens":1}}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["error", "message_stop"])
		XCTAssertEqual(results.first?.text, "boom")
		XCTAssertEqual(results.last?.promptTokens, 3)
		XCTAssertEqual(results.last?.completionTokens, 1)
	}

	func testResultSessionIDOverridesSystemInitSessionID() {
		var translator = ClaudeSDKNDJSONTranslator()
		_ = parse(#"{"type":"system","subtype":"init","session_id":"session-a"}"#, with: &translator)
		let results = parse(#"{"type":"result","session_id":"session-b"}"#, with: &translator)

		XCTAssertEqual(translator.cliSessionID, "session-b")
		XCTAssertEqual(results.last?.type, "message_stop")
		XCTAssertEqual(results.last?.providerSessionID, "session-b")
	}

	func testAssistantEnvelopeSessionIDCarriesForwardToLaterResult() {
		var translator = ClaudeSDKNDJSONTranslator()
		_ = parse(#"{"type":"assistant","session_id":"session-a","message":{"content":[{"type":"text","text":"hello"}]}}"#, with: &translator)
		let results = parse(#"{"type":"result"}"#, with: &translator)

		XCTAssertEqual(translator.cliSessionID, "session-a")
		XCTAssertEqual(results.last?.type, "message_stop")
		XCTAssertEqual(results.last?.providerSessionID, "session-a")
	}

	func testResultErrorDuringExecutionSuppressesKnownAbortSideEffects() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["SyntaxError: JSON Parse error: Unrecognized token '/'"]}"#
		let results = parse(line, with: &translator)

		// JSON parse errors during execution are known abort side effects and should be suppressed.
		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testResultErrorDuringExecutionEmitsGenuineErrors() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["Error: API rate limit exceeded"]}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["error", "message_stop"])
		XCTAssertEqual(results.first?.text, "Error: API rate limit exceeded")
	}

	func testResultErrorDuringExecutionSuppressesAbortArtifacts() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["SyntaxError: JSON Parse error: Unrecognized token '/'","Error: Request was aborted."]}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testResultErrorDuringExecutionSuppressesJsonParseWithNonFatalLockError() {
		var translator = ClaudeSDKNDJSONTranslator()
		// This is the exact error combination produced during interrupt steering:
		// JSON parse error from killed tool process + non-fatal lock warning.
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["SyntaxError: JSON Parse error: Unrecognized token '/'","Error: NON-FATAL: Lock acquisition failed for /some/path"]}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testResultErrorDuringExecutionSuppressesFullAbortErrorSet() {
		var translator = ClaudeSDKNDJSONTranslator()
		// This is the exact three-error combination observed in production during
		// interrupt steering: JSON parse error + non-fatal lock + MCP AbortError.
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["SyntaxError: JSON Parse error: Unrecognized token '/'","Error: NON-FATAL: Lock acquisition failed for /some/path","McpError: MCP error -32001: AbortError: The operation was aborted."]}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testResultErrorDuringExecutionSuppressesBundledCLIStackTraceArtifact() {
		var translator = ClaudeSDKNDJSONTranslator()
		let stackTrace = """
		SyntaxError: JSON Parse error: Unrecognized token '/'
		at <parse> (:0)
		at parse (unknown)
		at <anonymous> (/$bunfs/root/src/entrypoints/cli.js:98:1134)
		at K (/$bunfs/root/src/entrypoints/cli.js:96:27885)
		"""
		let errorObject: [String: Any] = [
			"type": "result",
			"subtype": "error_during_execution",
			"is_error": false,
			"errors": [stackTrace]
		]
		let data = try! JSONSerialization.data(withJSONObject: errorObject, options: [])
		let line = String(decoding: data, as: UTF8.self)
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testResultErrorDuringExecutionDoesNotSuppressLegitimateJSONParseErrors() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","subtype":"error_during_execution","is_error":false,"errors":["Error: failed to parse config: JSON Parse error at line 4"]}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["error", "message_stop"])
		XCTAssertEqual(results.first?.text, "Error: failed to parse config: JSON Parse error at line 4")
	}

	func testResultErrorSubtypeFallsBackToExplicitErrorMessage() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","subtype":"error_max_turns","is_error":false,"error":"Reached maximum turns"}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["error", "message_stop"])
		XCTAssertEqual(results.first?.text, "Reached maximum turns")
	}

	func testToolUseAndToolResultShareInvocationID() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"external_tool","input":{"x":1}}]}}"#
		let toolResultLine = #"{"type":"assistant","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}"#

		let toolUseResults = parse(toolUseLine, with: &translator)
		let toolResultResults = parse(toolResultLine, with: &translator)

		XCTAssertEqual(toolUseResults.count, 1)
		XCTAssertEqual(toolResultResults.count, 1)
		XCTAssertEqual(toolUseResults[0].type, "tool_call")
		XCTAssertEqual(toolResultResults[0].type, "tool_result")
		XCTAssertEqual(toolUseResults[0].toolName, "external_tool")
		XCTAssertEqual(toolResultResults[0].toolName, "external_tool")
		XCTAssertEqual(toolResultResults[0].toolOutput, "done")
		XCTAssertEqual(toolUseResults[0].toolInvocationID, toolResultResults[0].toolInvocationID)
	}

	func testStatusMessageEmitsStatusEventWithoutPermissionMode() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"system","subtype":"status","status":"compacting","permissionMode":"acceptEdits"}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.map(\.type), ["status"])
		XCTAssertEqual(results.first?.text, "Compacting context")
	}

	func testPermissionOnlyStatusEmitsNoUserFacingStatus() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"system","subtype":"status","permissionMode":"acceptEdits"}"#
		let results = parse(line, with: &translator)

		XCTAssertTrue(results.isEmpty)
	}

	func testAssistantThinkingBlockHonorsReasoningExtractionFlag() {
		for enabled in [false, true] {
		var translator = ClaudeSDKNDJSONTranslator(reasoningEnabled: enabled)
		let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Inspecting files"}]}}"#
		let results = parse(line, with: &translator)

		if enabled {
			XCTAssertEqual(results.map(\.type), ["reasoning"])
			XCTAssertEqual(results.first?.reasoning, "Inspecting files")
		} else {
			XCTAssertTrue(results.isEmpty)
		}
		}
	}

	func testThinkingDeltaHonorsReasoningExtractionFlag() {
		for enabled in [false, true] {
		var translator = ClaudeSDKNDJSONTranslator(reasoningEnabled: enabled)
		let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Reading tests"}}}"#
		let results = parse(line, with: &translator)

		if enabled {
			XCTAssertEqual(results.map(\.type), ["reasoning"])
			XCTAssertEqual(results.first?.reasoning, "Reading tests")
		} else {
			XCTAssertTrue(results.isEmpty)
		}
		}
	}

	func testStreamUsageEventsEmitUsageType() {
		var translator = ClaudeSDKNDJSONTranslator()
		let messageStart = #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":1}}}}"#
		let messageDelta = #"{"type":"stream_event","event":{"type":"message_delta","usage":{"input_tokens":3,"output_tokens":58}}}"#

		let startResult = parse(messageStart, with: &translator)
		let deltaResult = parse(messageDelta, with: &translator)

		XCTAssertEqual(startResult.first?.type, "usage")
		XCTAssertEqual(startResult.first?.promptTokens, 3)
		XCTAssertEqual(startResult.first?.completionTokens, 1)
		XCTAssertEqual(deltaResult.first?.type, "usage")
		XCTAssertEqual(deltaResult.first?.promptTokens, 3)
		XCTAssertEqual(deltaResult.first?.completionTokens, 58)
	}

	func testResultModelUsageEmitsContextWindowOnMessageStop() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"result","usage":{"input_tokens":3,"output_tokens":58},"modelUsage":{"claude-opus-4-6":{"inputTokens":3,"outputTokens":58,"cacheReadInputTokens":30660,"cacheCreationInputTokens":3303,"webSearchRequests":0,"costUSD":0.03743875,"contextWindow":200000,"maxOutputTokens":32000}}}"#
		let results = parse(line, with: &translator)

		let stop = results.last(where: { $0.type == "message_stop" })
		XCTAssertNotNil(stop)
		XCTAssertEqual(stop?.modelContextWindow, 200000)
	}

	func testStreamUsageContextUsedTokensIncludesCacheBreakdown() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":10,"cache_creation_input_tokens":7}}}}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "usage")
		XCTAssertEqual(results.first?.promptTokens, 3)
		XCTAssertEqual(results.first?.completionTokens, 1)
		XCTAssertEqual(results.first?.contextUsedTokens, 20)
	}

	func testRateLimitEventSkipsAllowedTelemetry() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","overageStatus":"rejected"}}"#
		let results = parse(line, with: &translator)
		XCTAssertTrue(results.isEmpty)
	}

	func testRateLimitEventEmitsSystemWhenNotAllowed() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"throttled","rateLimitType":"five_hour","overageStatus":"rejected"}}"#
		let results = parse(line, with: &translator)
		XCTAssertEqual(results.map(\.type), ["system"])
		XCTAssertEqual(results.first?.text, "Rate limit — throttled — five_hour — rejected")
	}

	func testUserToolResultEnvelopeParsesAndMatchesPriorToolUse() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}"#
		let userToolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","is_error":false,"content":[{"type":"text","text":"BASH_OK"}]}]}}"#

		let toolUseResults = parse(toolUseLine, with: &translator)
		let toolResultResults = parse(userToolResultLine, with: &translator)

		XCTAssertEqual(toolUseResults.count, 1)
		XCTAssertEqual(toolResultResults.count, 1)
		XCTAssertEqual(toolResultResults.first?.type, "tool_result")
		XCTAssertEqual(toolResultResults.first?.toolName, "Bash")
		XCTAssertEqual(toolResultResults.first?.toolOutput, "BASH_OK")
		XCTAssertEqual(toolResultResults.first?.toolIsError, false)
		XCTAssertEqual(toolUseResults.first?.toolInvocationID, toolResultResults.first?.toolInvocationID)
	}

	func testUserMessageMultipleToolResultsPreservesContentOrderAndInvocationIDs() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_first","name":"Read","input":{"file_path":"README.md"}},{"type":"tool_use","id":"toolu_second","name":"Bash","input":{"command":"echo second"}}]}}"#
		let userToolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_second","is_error":false,"content":[{"type":"text","text":"SECOND_OK"}]},{"type":"tool_result","tool_use_id":"toolu_first","is_error":false,"content":[{"type":"text","text":"FIRST_OK"}]}]},"parent_tool_use_id":null,"tool_use_result":{"content":"side-channel only; not used for ordering"}}"#

		let toolUseResults = parse(toolUseLine, with: &translator)
		let toolResultResults = parse(userToolResultLine, with: &translator)

		XCTAssertEqual(toolUseResults.count, 2)
		XCTAssertEqual(toolResultResults.map(\.type), ["tool_result", "tool_result"])
		XCTAssertEqual(toolResultResults.map(\.toolName), ["Bash", "Read"])
		XCTAssertEqual(toolResultResults.map(\.toolOutput), ["SECOND_OK", "FIRST_OK"])
		XCTAssertEqual(toolResultResults[0].toolInvocationID, toolUseResults[1].toolInvocationID)
		XCTAssertEqual(toolResultResults[1].toolInvocationID, toolUseResults[0].toolInvocationID)
	}

	func testTopLevelToolUseResultSideChannelAloneDoesNotEmitCorrelatedResult() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_side","name":"Bash","input":{"command":"echo hi"}}]}}"#
		let sideChannelOnlyLine = #"{"type":"user","message":{"role":"user","content":[]},"parent_tool_use_id":null,"tool_use_result":{"content":[{"type":"text","text":"SIDE_CHANNEL_OUTPUT"}],"tool_use_id":"toolu_side"}}"#

		_ = parse(toolUseLine, with: &translator)
		let results = parse(sideChannelOnlyLine, with: &translator)

		XCTAssertTrue(results.isEmpty)
	}

	func testTopLevelToolResultSerializesObjectPayload() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"tool_result","tool_name":"Bash","tool_result":{"type":"command_result","exitCode":0,"stdout":"done"},"is_error":false}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "tool_result")
		XCTAssertEqual(results.first?.toolName, "Bash")
		XCTAssertEqual(results.first?.toolIsError, false)
		XCTAssertTrue(results.first?.toolOutput?.contains("\"exitCode\" : 0") == true)
	}

	func testUserToolResultSupportsCamelCaseToolUseIdKey() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}"#
		let userToolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","toolUseId":"toolu_1","is_error":false,"content":[{"type":"text","text":"BASH_OK"}]}]}}"#

		_ = parse(toolUseLine, with: &translator)
		let results = parse(userToolResultLine, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "tool_result")
		XCTAssertEqual(results.first?.toolName, "Bash")
	}

	func testUserToolResultWithoutIsErrorInfersSuccessForNativeTool() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"README.md"}}]}}"#
		let userToolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_read","content":[{"type":"text","text":"file content"}]}]}}"#

		_ = parse(toolUseLine, with: &translator)
		let results = parse(userToolResultLine, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "tool_result")
		XCTAssertEqual(results.first?.toolName, "Read")
		XCTAssertEqual(results.first?.toolIsError, false)
	}

	func testUserToolResultWithoutIsErrorStaysNilForRepoPromptTool() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_rp","name":"mcp__RepoPrompt__read_file","input":{"path":"README.md"}}]}}"#
		let userToolResultLine = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_rp\",\"content\":[{\"type\":\"text\",\"text\":\"## File Read ✅\"}]}]}}"

		_ = parse(toolUseLine, with: &translator)
		let results = parse(userToolResultLine, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "tool_result")
		XCTAssertEqual(results.first?.toolName, "mcp__RepoPrompt__read_file")
		XCTAssertNil(results.first?.toolIsError)
	}

	func testTopLevelToolUseAndResultUsingNameKeyInferSuccessForNativeRead() {
		var translator = ClaudeSDKNDJSONTranslator()
		let toolUseLine = #"{"type":"tool_use","id":"toolu_read_top","name":"Read","input":{"file_path":"README.md"}}"#
		let toolResultLine = #"{"type":"tool_result","tool_use_id":"toolu_read_top","name":"Read","tool_result":{"status":"completed","content":[{"type":"text","text":"hello"}]}}"#

		let toolUseResults = parse(toolUseLine, with: &translator)
		let toolResultResults = parse(toolResultLine, with: &translator)

		XCTAssertEqual(toolUseResults.count, 1)
		XCTAssertEqual(toolUseResults.first?.toolName, "Read")
		XCTAssertEqual(toolResultResults.count, 1)
		XCTAssertEqual(toolResultResults.first?.toolName, "Read")
		XCTAssertEqual(toolResultResults.first?.toolIsError, false)
		XCTAssertEqual(toolUseResults.first?.toolInvocationID, toolResultResults.first?.toolInvocationID)
	}

	func testTopLevelToolResultInfersFailureFromNestedStatusForNativeTool() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"tool_result","tool_name":"Read","tool_result":{"status":"failed","error":"missing file"}}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.type, "tool_result")
		XCTAssertEqual(results.first?.toolName, "Read")
		XCTAssertEqual(results.first?.toolIsError, true)
	}

	func testTopLevelToolResultStaysNilForRepoPromptToolWithoutExplicitIsError() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"tool_result","tool_name":"mcp__RepoPrompt__read_file","tool_result":{"status":"completed"}}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.toolName, "mcp__RepoPrompt__read_file")
		XCTAssertNil(results.first?.toolIsError)
	}

	func testTopLevelToolResultIgnoresIsErrorForRepoPromptTool() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"tool_result","tool_name":"mcp__RepoPrompt__read_file","is_error":true,"tool_result":{"status":"failed"}}"#
		let results = parse(line, with: &translator)

		XCTAssertEqual(results.count, 1)
		XCTAssertEqual(results.first?.toolName, "mcp__RepoPrompt__read_file")
		XCTAssertNil(results.first?.toolIsError)
	}

	func testStreamEventMessageStopEmitsMessageStop() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"stream_event","event":{"type":"message_stop"}}"#
		let results = parse(line, with: &translator)
		XCTAssertEqual(results.map(\.type), ["message_stop"])
	}

	func testStreamEventMessageDeltaStopReasonEmitsUsageAndMessageStop() {
		var translator = ClaudeSDKNDJSONTranslator()
		let line = #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":5,"output_tokens":8}}}"#
		let results = parse(line, with: &translator)
		XCTAssertEqual(results.map(\.type), ["usage", "message_stop"])
		XCTAssertEqual(results.first?.promptTokens, 5)
		XCTAssertEqual(results.first?.completionTokens, 8)
		XCTAssertEqual(results.last?.stopReason, "end_turn")
	}
}
