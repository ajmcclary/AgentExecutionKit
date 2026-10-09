import XCTest
import AIClientKit
import AgentClaudeHeadless
import AgentClaudeProtocol

final class ClaudeHeadlessParserTests: XCTestCase {
    private let parser = ClaudeHeadlessEventParser(reasoningEnabled: true)
    private func parse(_ text: String) throws -> [AIStreamResult] { try parser.parseStreamEvents(Data(text.utf8)) }
    func testWhitespaceAndUnsupportedTopLevelAreEmpty() throws {
        for text in [" \n", "[]", "{}"] { XCTAssertTrue(try parse(text).isEmpty) }
        for text in ["42", "\"text\"", "null"] { XCTAssertThrowsError(try parse(text)) }
    }
    func testMalformedJSONThrows() { XCTAssertThrowsError(try parse("{bad")) }
    func testLegacyContentAndNestedTextPreserveOrder() throws {
        let values = try parse(#"[{"type":"message","content":["a",{"text":"b"}]},{"type":"assistant","message":{"content":[{"type":"text","text":"c"}]}}]"#)
        XCTAssertEqual(values.map(\.type), ["content", "content"])
        XCTAssertEqual(values.map(\.text), ["ab", "c"])
    }
    func testAssistantBlocksPreserveTextThinkingToolsAndResultObjects() throws {
        let values = try parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"},{"type":"thinking","thinking":"thought"},{"type":"tool_use","name":"read_file","input":{"path":"README.md"}},{"type":"tool_result","name":"read_file","content":{"ok":true}}]}}"#)
        XCTAssertEqual(values.map(\.type), ["content", "reasoning", "tool_call", "tool_result"])
        XCTAssertEqual(values[1].reasoning, "thought")
        XCTAssertEqual(values[2].toolName, "read_file")
        XCTAssertEqual(values[2].toolArgsJSON, "{\n  \"path\" : \"README.md\"\n}")
        XCTAssertEqual(values[3].toolResultJSON, "{\n  \"ok\" : true\n}")
    }
    func testReasoningPolicyAppliesToBlocksLegacyAndDeltas() throws {
        let disabled = ClaudeHeadlessEventParser(reasoningEnabled: false)
        for text in [#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"x"}]}}"#,
                     #"{"type":"message","reasoning":"x"}"#,
                     #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"x"}}}"#] {
            XCTAssertEqual(try parse(text).first?.reasoning, "x")
            XCTAssertTrue(try disabled.parseStreamEvents(Data(text.utf8)).isEmpty)
        }
    }
    func testTextDeltaAndEmptyUnknownDeltas() throws {
        XCTAssertEqual(try parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"delta"}}}"#).first?.text, "delta")
        for delta in [#"{"type":"text_delta","text":""}"#, #"{"type":"input_json_delta","partial_json":"x"}"#] {
            XCTAssertTrue(try parse("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":" + delta + "}}").isEmpty)
        }
    }
    func testResultStopReasonFinalContentUsageAndRawSessionIdentity() throws {
        let values = try parse(#"{"type":"result","stop_reason":" max_tokens ","result":"final","session_id":" exact session ","usage":{"input_tokens":12,"output_tokens":7},"total_cost_usd":0.3}"#)
        XCTAssertEqual(values.map(\.type), ["system", "final_content", "message_stop"])
        XCTAssertEqual(values[0].text, "Claude stop reason: max_tokens")
        XCTAssertEqual(values[1].text, "final")
        XCTAssertEqual(values[2].providerSessionID, " exact session ")
        XCTAssertEqual(values[2].promptTokens, 12); XCTAssertEqual(values[2].completionTokens, 7)
        XCTAssertEqual(values[2].cost, 0.3)
    }
    func testCamelCaseUsageAndSessionAndEndTurnDoNotEmitSystem() throws {
        let values = try parse(#"{"type":"result","stopReason":"end_turn","sessionId":"legacy","usage":{"inputTokens":"4","outputTokens":2.9}}"#)
        XCTAssertEqual(values.map(\.type), ["message_stop"])
        XCTAssertEqual(values[0].promptTokens, 4); XCTAssertEqual(values[0].completionTokens, 2)
        XCTAssertEqual(values[0].providerSessionID, "legacy")
    }
    func testMissingOrUnrepresentableUsageIsAbsent() throws {
        for usage in ["{}", "{\"input_tokens\":1}", "{\"input_tokens\":1e100,\"output_tokens\":2}"] {
            let value = try parse("{\"type\":\"result\",\"usage\":" + usage + "}").first
            XCTAssertNil(value?.promptTokens); XCTAssertNil(value?.completionTokens)
        }
    }
    func testLegacyToolsAndEmptyArguments() throws {
        let values = try parse(#"[{"type":"tool_use","tool_name":{"text":"read"},"tool_args":{}},{"type":"tool_result","tool_name":"read","tool_result":["ok",{"text":"!"}]}]"#)
        XCTAssertEqual(values[0].toolName, "read"); XCTAssertNil(values[0].toolArgsJSON)
        XCTAssertEqual(values[1].toolOutput, "ok!")
    }
    func testLifecycleProgressAuthAndSystemMessages() throws {
        let values = try parse(#"[{"type":"init"},{"type":"system","subtype":"init"},{"type":"system","message":"notice"},{"type":"tool_progress","progress":" working "},{"type":"auth_status","authStatus":" ready ","message":" signed in "}]"#)
        XCTAssertEqual(values.map(\.type), [AIStreamResult.lifecycleType, AIStreamResult.lifecycleType, "system", "system", "system"])
        XCTAssertEqual(values[0].text, "initialized")
        XCTAssertEqual(values[3].text, "working"); XCTAssertEqual(values[4].text, "ready — signed in")
    }
    func testUserEchoUnknownAndNonDictionaryArrayElementsAreIgnored() throws {
        XCTAssertTrue(try parse(#"[null,42,"x",{"type":"user","content":"echo"},{"type":"future"},{"type":"auth_status"},{"type":"system"}]"#).isEmpty)
    }
    func testStructuredErrorsWinOverPlainTextAndNewestStructuredWins() {
        XCTAssertEqual(parser.extractCLIErrorDetail(fromStdout: Data("{\"error\":\"old\"}\n{bad\n{\"message\":\" newest \"}\nplain last".utf8)), "newest")
    }
    func testPlainErrorFallbackSkipsJSONAndWhitespace() {
        XCTAssertEqual(parser.extractCLIErrorDetail(fromStdout: Data("first\n last \n{}\n[]\n ".utf8)), "last")
        XCTAssertNil(parser.extractCLIErrorDetail(fromStdout: Data()))
    }
    func testPromptDecorationPreservesHistoricalWhitespaceRules() {
        XCTAssertEqual(ClaudePromptDelivery.decoratedUserMessage(" user \n", instructions: " instructions \n"), "<claude_code_instructions>\ninstructions\n</claude_code_instructions>\n\n user \n")
        XCTAssertEqual(ClaudePromptDelivery.decoratedUserMessage(" \n", instructions: "x"), "<claude_code_instructions>\nx\n</claude_code_instructions>")
        XCTAssertEqual(ClaudePromptDelivery.decoratedUserMessage(" user ", instructions: " \n"), " user ")
    }
}
