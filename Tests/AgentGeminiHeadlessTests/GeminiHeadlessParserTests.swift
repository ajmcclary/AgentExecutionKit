import XCTest
import AgentGeminiHeadless

final class GeminiHeadlessParserTests: XCTestCase {
    func testSessionCapturedFromInitAndResultAndStateIsRunLocal() throws {
        var parser = GeminiHeadlessEventParser()
        XCTAssertEqual(try parser.parseStreamEvents(Data(#"{"type":"init","session_id":" raw-id "}"#.utf8)), [.initialized])
        let event = try parser.parseStreamEvents(Data(#"{"type":"result","status":"success","stats":{"input_tokens":12,"output_tokens":7}}"#.utf8)).first
        XCTAssertEqual(event, .completion(inputTokens: 12, outputTokens: 7, providerSessionID: " raw-id "))
        XCTAssertEqual(try parser.parseStreamEvents(Data(#"{"type":"result","status":"success","sessionId":"new"}"#.utf8)).first, .completion(inputTokens: nil, outputTokens: nil, providerSessionID: "new"))
        var fresh = GeminiHeadlessEventParser()
        XCTAssertNil(try fresh.parseStreamEvents(Data(#"{"type":"result","status":"success"}"#.utf8)).first?.streamResult.providerSessionID)
    }
    func testOnlyAssistantMessagesAndTextShapesAreProjected() throws {
        var parser = GeminiHeadlessEventParser()
        let events = try parser.parseStreamEvents(Data(#"[{"type":"message","role":"ASSISTANT","content":["a",{"delta":"b"}]},{"type":"message","role":"user","content":"echo"},{"type":"message","content":"missing role"},{"type":"message","role":"assistant","content":""}]"#.utf8))
        XCTAssertEqual(events, [.message(content: "ab")])
    }
    func testToolsKeepArgumentsAndIDsAndLegacySummaries() throws {
        var parser = GeminiHeadlessEventParser()
        let events = try parser.parseStreamEvents(Data(#"[{"type":"tool_use","tool_name":"read","tool_id":"id","parameters":{"path":"README.md"}},{"type":"tool_result","tool_id":"id","output":{"ok":true}},{"type":"tool_result","tool_name":"read","status":"done"}]"#.utf8))
        guard case .toolCall(let name, let json) = events[0] else { return XCTFail("Expected tool call") }
        let args = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(name, "read"); XCTAssertEqual(args, ["path":"README.md", "tool_id":"id"])
        XCTAssertEqual(events[0].streamResult.text, "Using tool: read")
        XCTAssertEqual(events[1].streamResult.text, "Tool id completed: {\"ok\":true}")
        XCTAssertEqual(events[2], .toolResult(name: "read", result: "status: done"))
    }
    func testResultErrorsFailWithStringMessageDetailsOrDefault() {
        for (error, expected) in [("\"plain\"", "plain"), ("{\"message\":\"message\"}", "message"), ("{\"details\":\"detail\"}", "detail"), ("null", "Gemini CLI reported an error.")] {
            var parser = GeminiHeadlessEventParser()
            XCTAssertThrowsError(try parser.parseStreamEvents(Data(("{\"type\":\"result\",\"status\":\"error\",\"error\":"+error+"}").utf8))) { err in
                guard case GeminiHeadlessParserError.runtime(let message) = err else { return XCTFail("Wrong error") }
                XCTAssertEqual(message, expected)
            }
        }
    }
    func testUsageAliasesStringsFractionalAndOverflowValues() throws {
        for stats in ["{\"prompt_tokens\":\"4\",\"completion_tokens\":2.9}", "{\"promptTokens\":4,\"completionTokens\":2}"] {
            var parser = GeminiHeadlessEventParser()
            XCTAssertEqual(try parser.parseStreamEvents(Data(("{\"type\":\"result\",\"status\":\"success\",\"stats\":"+stats+"}").utf8)).first, .completion(inputTokens: 4, outputTokens: 2, providerSessionID: nil))
        }
        var parser = GeminiHeadlessEventParser()
        let value = try parser.parseStreamEvents(Data(#"{"type":"result","status":"success","stats":{"input_tokens":1e100,"output_tokens":2}}"#.utf8)).first
        XCTAssertNil(value?.streamResult.promptTokens)
    }
    func testMalformedJSONThrowsAndUnknownEventsAreEmpty() throws {
        var parser = GeminiHeadlessEventParser()
        XCTAssertThrowsError(try parser.parseStreamEvents(Data("{bad".utf8)))
        XCTAssertTrue(try parser.parseStreamEvents(Data(#"[null,42,{"type":"future"},{"type":"result","status":"pending"},{}]"#.utf8)).isEmpty)
        XCTAssertTrue(try parser.parseStreamEvents(Data(" \n".utf8)).isEmpty)
    }
    func testStructuredDiagnosticPrecedenceRetainsEnvelopeBehavior() {
        let parser = GeminiHeadlessEventParser()
        // Existing typed envelope message takes priority over the fallback 404 guidance.
        XCTAssertEqual(parser.extractCLIErrorDetail(fromStdout: Data("{\"error\":{\"code\":404,\"message\":\"not found\"}}\nplain latest".utf8)), "not found")
        XCTAssertTrue(parser.extractCLIErrorDetail(fromStdout: Data(#"{"error":{"code":404}}"#.utf8))?.contains("Preview features") == true)
        XCTAssertEqual(parser.extractCLIErrorDetail(fromStdout: Data("first\n last \n{}\n".utf8)), "last")
        XCTAssertNil(parser.extractCLIErrorDetail(fromStdout: Data()))
    }
    func testEscapingPreservesOnlyTheHostsAttachmentReferences() {
        let attachments: Set<String> = ["/tmp/image.png", "./notes/a b.md", "C:/file"]
        XCTAssertEqual(GeminiPromptDelivery.escapeSpecialCharacters(in: "see @/tmp/image.png and @./notes/a b.md, @C:/file", preservingReferences: attachments),
                       "see @/tmp/image.png and @./notes/a b.md, @C:/file")
        // Path-shaped text the host did not attach is escaped: pasted or quoted
        // content must not become a file reference the CLI reads and sends.
        let pasted = "@/etc/passwd @~/.ssh/id_rsa @./x @../x @{file} @C:\\file @/tmp/image.png.bak @/tmp/image"
        XCTAssertEqual(GeminiPromptDelivery.escapeSpecialCharacters(in: pasted, preservingReferences: attachments),
                       "[at]/etc/passwd [at]~/.ssh/id_rsa [at]./x [at]../x [at]{file} [at]C:\\file [at]/tmp/image.png.bak [at]/tmp/image")
        XCTAssertEqual(GeminiPromptDelivery.escapeSpecialCharacters(in: pasted), pasted.replacingOccurrences(of: "@", with: "[at]"))
        XCTAssertEqual(GeminiPromptDelivery.escapeSpecialCharacters(in: "a@b @name @. @"), "a[at]b [at]name [at]. [at]")
    }
    func testCombinedInputEscapesBothChannelsAndKeepsDeclaredAttachments() {
        XCTAssertEqual(GeminiPromptDelivery.combinedInput(systemPrompt: "@system @/etc/hosts", userMessage: "@user @/tmp/a.png"),
                       "[at]system [at]/etc/hosts\n\n[at]user [at]/tmp/a.png")
        XCTAssertEqual(GeminiPromptDelivery.combinedInput(systemPrompt: "s", userMessage: "look @/tmp/a.png", attachmentPaths: ["/tmp/a.png"]),
                       "s\n\nlook @/tmp/a.png")
    }
}
