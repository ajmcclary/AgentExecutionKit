import XCTest
import Foundation
import AIClientKit
import ClaudeRuntimeKit
import AgentClaudeProtocol
import AgentClaudeContent
import AgentClaudeEvents

final class ClaudeContentPipelineTests: XCTestCase {
	private let identity = ClaudeUsageIdentity(sessionID: "s", messageID: "turn", phase: .turnAggregate)
	private func batch(type: String = "result", results: [AIStreamResult], identities: [ClaudeUsageIdentity]? = nil) -> ClaudeNativeTranslationBatch {
		.init(envelope: .decode(line: Data("{\"type\":\"\(type)\"}".utf8)), results: results, diagnostics: [],
			normalizedEvents: (identities ?? [identity]).map { .usage(.init(identity: $0, scope: .topLevel,
				breakdown: .init(inputTokens: 2, outputTokens: 3, cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
				modelContextWindow: nil, costUSD: nil, extra: [:])) })
	}
	private func labels(_ frame: ClaudeContentFrame) -> [String] {
		frame.steps.map { step in
			switch step {
			case .sessionID(let id): return "session:\(id)"
			case .observeResult(let result, let suppressed): return "observe:\(result.type):\(suppressed)"
			case .emit(.stream(let result)): return "stream:\(result.type)"
			case .emit(.turnAggregateIdentity(let id)): return "identity:\(id.messageID ?? "nil")"
			case .emit: return "unexpected"
			}
		}
	}
	func testIdentityImmediatelyPrecedesFirstResultStopAndLogPrecedesIdentity() {
		let frame = ClaudeContentFrame.project(batch: batch(results: [.init(type: "final_content", text: "done"), .init(type: "message_stop", text: nil), .init(type: "message_stop", text: nil)]), authority: .legacy)
		XCTAssertEqual(labels(frame), ["observe:final_content:false", "stream:final_content", "observe:message_stop:false", "identity:turn", "stream:message_stop", "observe:message_stop:false", "stream:message_stop"])
	}
	func testStreamBoundariesNeverAdoptTurnAggregateIdentity() {
		for type in ["stream_event", "assistant", "Result", " result"] {
			let frame = ClaudeContentFrame.project(batch: batch(type: type, results: [.init(type: "message_stop", text: nil)]), authority: .legacy)
			XCTAssertEqual(labels(frame), ["observe:message_stop:false", "stream:message_stop"], type)
		}
	}
	func testNoIdentityWithoutStopOrNamedAggregate() {
		for ids in [[], [.init(sessionID: "s", messageID: nil, phase: .turnAggregate)], [.init(sessionID: "s", messageID: "m", phase: .assistantSnapshot)]] as [[ClaudeUsageIdentity]] {
			let frame = ClaudeContentFrame.project(batch: batch(results: [.init(type: "message_stop", text: nil)], identities: ids), authority: .legacy)
			XCTAssertEqual(labels(frame), ["observe:message_stop:false", "stream:message_stop"])
		}
		let noStop = ClaudeContentFrame.project(batch: batch(results: [.init(type: "content", text: "hello")]), authority: .legacy)
		XCTAssertFalse(labels(noStop).contains { $0.hasPrefix("identity:") })
	}
	func testOnlyFirstValidAggregateNamesResultInBothModes() {
		let source = batch(results: [.init(type: "message_stop", text: nil)], identities: [identity, .init(sessionID: "s", messageID: "second", phase: .turnAggregate)])
		// Normalized lane needs a result boundary; the legacy sentinel already has one.
		let sourceWithResult = ClaudeNativeTranslationBatch(envelope: source.envelope, results: source.results, diagnostics: [], normalizedEvents: source.normalizedEvents + [.result(.init(sessionID: "s", subtype: nil, isError: false, text: nil, stopReason: nil, extra: [:]))])
		for authority in ClaudeProjectionAuthority.allCases {
			XCTAssertEqual(labels(ClaudeContentFrame.project(batch: sourceWithResult, authority: authority)).filter { $0.hasPrefix("identity:") }, ["identity:turn"])
		}
	}
	func testSessionObservationOrderIncludesSuppressedResultAndRepeatedRawIdentity() {
		let frame = ClaudeContentFrame.project(batch: batch(results: [.init(type: "system", text: "Task started — job", providerSessionID: "s"), .init(type: "content", text: "hello", providerSessionID: " s ")]), authority: .legacy, translatorSessionID: "s")
		XCTAssertEqual(labels(frame), ["session:s", "session:s", "observe:system:true", "session: s ", "observe:content:false", "stream:content"])
	}
	func testEmptySessionIDsAreSkipped() {
		let frame = ClaudeContentFrame.project(batch: batch(results: [.init(type: "content", text: "hello", providerSessionID: "")]), authority: .legacy, translatorSessionID: "")
		XCTAssertEqual(labels(frame), ["observe:content:false", "stream:content"])
	}
	func testRunStateAndReasoningRemainForwardedAlongsideFilteredTasks() {
		let source = batch(results: [.init(type: "system", text: "Task update — failed"), .init(type: "task_progress", text: "Task update"), .init(type: "session_state_changed", text: "idle"), .init(type: "reasoning", text: "thinking")])
		XCTAssertEqual(labels(ClaudeContentFrame.project(batch: source, authority: .legacy)), ["observe:system:true", "observe:task_progress:false", "stream:task_progress", "observe:session_state_changed:false", "stream:session_state_changed", "observe:reasoning:false", "stream:reasoning"])
	}
	func testProjectedResultPreservesAllFieldsAndInvocationIdentity() throws {
		let id = UUID()
		let result = AIStreamResult(type: "tool_result", text: "value", reasoning: "thought", promptTokens: 2, completionTokens: 3, cost: 0.5, toolName: "read", toolArgs: "args", toolOutput: "out", toolInvocationID: id, toolResultJSON: "[]", toolArgsJSON: "{}", toolIsError: true, providerSessionID: "s", stopReason: "end", modelContextWindow: 100, contextUsedTokens: 20, contentMessageID: "message")
		let frame = ClaudeContentFrame.project(batch: batch(results: [result]), authority: .legacy)
		guard case .emit(.stream(let emitted)) = try XCTUnwrap(frame.steps.last) else { return XCTFail("missing stream") }
		XCTAssertEqual(emitted.type, result.type); XCTAssertEqual(emitted.text, result.text)
		XCTAssertEqual(emitted.reasoning, result.reasoning); XCTAssertEqual(emitted.promptTokens, result.promptTokens)
		XCTAssertEqual(emitted.completionTokens, result.completionTokens); XCTAssertEqual(emitted.cost, result.cost)
		XCTAssertEqual(emitted.toolName, result.toolName); XCTAssertEqual(emitted.toolArgs, result.toolArgs)
		XCTAssertEqual(emitted.toolOutput, result.toolOutput); XCTAssertEqual(emitted.toolInvocationID, id)
		XCTAssertEqual(emitted.toolArgsJSON, result.toolArgsJSON); XCTAssertEqual(emitted.toolResultJSON, result.toolResultJSON)
		XCTAssertEqual(emitted.toolIsError, result.toolIsError); XCTAssertEqual(emitted.providerSessionID, result.providerSessionID)
		XCTAssertEqual(emitted.stopReason, result.stopReason); XCTAssertEqual(emitted.modelContextWindow, result.modelContextWindow)
		XCTAssertEqual(emitted.contextUsedTokens, result.contextUsedTokens); XCTAssertEqual(emitted.contentMessageID, result.contentMessageID)
	}
	private func pipeline(_ authority: ClaudeProjectionAuthority = .normalized, externallyTracked: @escaping @Sendable (String) -> Bool = { _ in false }) -> ClaudeContentPipeline {
		.init(authority: authority, policy: .init(isExternallyTrackedTool: externallyTracked, reasoningEnabled: false, diagnostics: { _ in }, reasoningDiagnostics: { _ in }))
	}
	func testDiagnosticsAreAccumulatedSeparatelyAndDoNotEnterStream() {
		let pipeline = pipeline()
		let frame = pipeline.translate(Data("not-json".utf8))
		XCTAssertTrue(frame.results.isEmpty); XCTAssertTrue(frame.steps.isEmpty)
		XCTAssertEqual(pipeline.diagnostics.totalCount, 1)
		_ = pipeline.translate(Data("not-json".utf8))
		XCTAssertEqual(pipeline.diagnostics.totalCount, 2)
		XCTAssertEqual(pipeline.diagnostics.samples.count, 1)
		_ = pipeline.translate(Data("  \n".utf8))
		XCTAssertEqual(pipeline.diagnostics.totalCount, 2)
	}
	func testTranslationRetainsSessionAndToolCorrelationAcrossFrames() throws {
		let pipeline = pipeline()
		let call = pipeline.translate(Data(#"{"type":"assistant","session_id":"s","message":{"id":"m","content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"a"}}]}}"#.utf8))
		let reply = pipeline.translate(Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}"#.utf8))
		let callID = try XCTUnwrap(call.results.first { $0.type == "tool_call" }?.toolInvocationID)
		XCTAssertEqual(reply.results.first { $0.type == "tool_result" }?.toolInvocationID, callID)
		XCTAssertEqual(labels(reply).first, "session:s")
	}
	func testIndependentClientsDoNotShareSessionOrInvocationState() throws {
		let first = pipeline(), second = pipeline()
		let payload = Data(#"{"type":"assistant","session_id":"s","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Read","input":{}}]}}"#.utf8)
		let a = first.translate(payload), b = second.translate(payload)
		XCTAssertNotEqual(try XCTUnwrap(a.results.first?.toolInvocationID), try XCTUnwrap(b.results.first?.toolInvocationID))
		XCTAssertTrue(labels(pipeline().translate(Data(#"{"type":"system","subtype":"init"}"#.utf8))).allSatisfy { !$0.hasPrefix("session:") })
	}
	func testAuthorityVocabularyIsStable() {
		XCTAssertEqual(ClaudeProjectionAuthority.allCases.map(\.rawValue), ["normalized", "legacy"])
	}
}
