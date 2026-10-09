import XCTest
import Foundation
import AgentCodexExec
import AgentCLIExecution
import AgentHeadlessContracts
import AIClientKit

final class CodexExecClientTests: XCTestCase {
	private actor Execution: AgentCLIExecuting {
		let events: [AgentCLIRunner.StreamEvent]
		let hold: Bool
		var starts = 0; var cancels = 0; var input: String?
		var continuation: AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.Continuation?
		init(_ events: [AgentCLIRunner.StreamEvent], hold: Bool = false) { self.events = events; self.hold = hold }
		func run(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?, additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AgentCLIRunner.Result {
			throw FixtureError.unexpected
		}
		func runStreaming(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?, additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error> {
			starts += 1; input = stdin
			let (stream, continuation) = AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.makeStream()
			self.continuation = continuation
			for event in events { continuation.yield(event) }
			if !hold { continuation.finish() }
			return stream
		}
		func cancelAll() async { cancels += 1; continuation?.finish() }
		func send(_ event: AgentCLIRunner.StreamEvent) { continuation?.yield(event) }
	}
	private enum FixtureError: Error { case unexpected }
	private actor Host {
		var executions: [Execution]
		var prepared = 0; var cleaned: [UUID] = []; var broken: [String] = []
		var emissions: [UUID: @Sendable (AIStreamResult) -> Void] = [:]
		var observationIDs: [UUID] = []
		init(_ executions: [Execution]) { self.executions = executions }
		func prepare(_ id: UUID?) throws -> CodexExecRunContext {
			guard !executions.isEmpty else { throw FixtureError.unexpected }
			prepared += 1
			return .init(runID: id ?? UUID(), arguments: ["exec", "--json"], execution: executions.removeFirst())
		}
		func observe(_ context: CodexExecRunContext, emit: @escaping @Sendable (AIStreamResult) -> Void) { emissions[context.id] = emit; observationIDs.append(context.id) }
		func emitOldObservation() { if let id = observationIDs.first { emissions[id]?(.init(type: "content", text: "stale")) } }
		func clean(_ context: CodexExecRunContext) { cleaned.append(context.id) }
		func record(_ server: String) { broken.append(server) }
	}
	private var policy: CodexExecToolPolicy { .init(isExternallyTrackedToolName: { $0.hasPrefix("mcp__fixture__") }, isExternallyTrackedServer: { $0 == "fixture" }) }
	private func client(_ host: Host) -> CodexExecClient {
		CodexExecClient(host: .init(validate: {}, prepare: { try await host.prepare($0) },
			startObservation: { await host.observe($0, emit: $1) }, cleanup: { await host.clean($0) },
			recordBrokenServer: { await host.record($0) }, modelUnavailableError: { AIProviderError.invalidConfiguration(detail: "Host guidance: " + $0) }, diagnostics: { _ in }), toolPolicy: policy)
	}
	private func out(_ text: String) -> AgentCLIRunner.StreamEvent { .stdout(Data(text.utf8)) }
	private func err(_ text: String) -> AgentCLIRunner.StreamEvent { .stderr(Data(text.utf8)) }
	private func collect(_ client: CodexExecClient) async throws -> [AIStreamResult] {
		var results: [AIStreamResult] = []
		let provider: any HeadlessAgentProviding = client
		for try await value in try await provider.streamAgentMessage(.init(systemPrompt: "system", userMessage: "user"), runID: nil) { results.append(value) }
		return results
	}

	func testChunkedContentReasoningAndUsageKeepOrderAndOneCompletion() async throws {
		let execution = Execution([out("{\"type\":\"item.com"), out("pleted\",\"item\":{\"type\":\"reasoning\",\"text\":\"think\"}}\n"),
			out(#"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"# + "\n"),
			out(#"{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":4},"total_cost_usd":0.2}"# + "\n")])
		let host = Host([execution]); let results = try await collect(client(host))
		XCTAssertEqual(results.map(\.type), ["reasoning", "content", "message_stop"])
		XCTAssertEqual(results[0].reasoning, "think"); XCTAssertEqual(results[1].text, "hello")
		XCTAssertEqual(results[2].promptTokens, 3); XCTAssertEqual(results[2].completionTokens, 4)
		let input = await execution.input; XCTAssertEqual(input, "system\n\nuser")
		let cleaned = await host.cleaned; XCTAssertEqual(cleaned.count, 1)
	}
	func testTrailingContentAndCleanExitInjectExactlyOneStop() async throws {
		let host = Host([Execution([out(#"{"id":"0","msg":{"type":"agent_message","message":"hello"}}"#), .terminated(status: 0, timedOut: false)])])
		let values = try await collect(client(host))
		XCTAssertEqual(values.map(\.type), ["content", "message_stop"])
	}
	func testDuplicateAndTrailingCompletionAreNotEmittedTwice() async throws {
		let host = Host([Execution([out("{\"type\":\"done\"}\n{\"type\":\"done\"}\n{\"type\":\"done\"}")])])
		let values = try await collect(client(host)); XCTAssertEqual(values.filter { $0.type == "message_stop" }.count, 1)
	}
	func testMissingExitWithoutCompletionFails() async {
		let host = Host([Execution([])])
		do { _ = try await collect(client(host)); XCTFail("Expected missing termination") }
		catch { XCTAssertTrue(error.localizedDescription.contains("did not report a termination status")) }
		let clean = await host.cleaned; XCTAssertEqual(clean.count, 1)
	}
	func testBrokenServerRetriesOnlyOnceAndCleansEveryAttempt() async throws {
		let first = Execution([err("MCP client for `broken` failed to start\n"), .terminated(status: 1, timedOut: false)])
		let second = Execution([out("{\"type\":\"done\"}\n")])
		let host = Host([first, second]); _ = try await collect(client(host))
		let count = await host.prepared; let broken = await host.broken; let clean = await host.cleaned
		XCTAssertEqual(count, 2); XCTAssertEqual(broken, ["broken"]); XCTAssertEqual(Set(clean).count, 2)
	}
	func testSecondBrokenServerFailureDoesNotCreateAThirdAttempt() async {
		let failure: [AgentCLIRunner.StreamEvent] = [err("MCP client for `broken` failed to start\n"), .terminated(status: 1, timedOut: false)]
		let host = Host([Execution(failure), Execution(failure)])
		do { _ = try await collect(client(host)); XCTFail("Expected failure") } catch {}
		let count = await host.prepared; let broken = await host.broken
		XCTAssertEqual(count, 2); XCTAssertEqual(broken.count, 1)
	}
	func testStdoutErrorTakesPrecedenceOverBrokenServerRetry() async {
		let host = Host([Execution([out("{\"type\":\"error\",\"message\":\"primary\"}\n"), err("MCP client for `broken` failed to start\n"), .terminated(status: 1, timedOut: false)])])
		do { _ = try await collect(client(host)); XCTFail("Expected primary error") }
		catch { XCTAssertEqual(error.localizedDescription, "primary") }
		let broken = await host.broken; XCTAssertTrue(broken.isEmpty)
	}
	func testUnavailableModelUsesHostGuidanceWithoutSubstitution() async {
		let host = Host([Execution([out("{\"type\":\"error\",\"message\":\"model_not_found\"}\n"), .terminated(status: 1, timedOut: false)])])
		do { _ = try await collect(client(host)); XCTFail("Expected unavailable model") }
		catch { XCTAssertEqual(error.localizedDescription, "Host guidance: model_not_found") }
		let count = await host.prepared; XCTAssertEqual(count, 1)
	}
	func testTimeoutAndAuthenticationFailuresKeepTheirMessages() async {
		for (stderr, timeout, expected) in [("", true, "codex exec timed out. Please retry shortly."), ("not authenticated", false, "Codex CLI not authenticated. Run `codex login` in a terminal and try again.")] {
			let host = Host([Execution([err(stderr), .terminated(status: 1, timedOut: timeout)])])
			do { _ = try await collect(client(host)); XCTFail("Expected failure") } catch { XCTAssertEqual(error.localizedDescription, expected) }
		}
	}
	func testDiagnosticNoiseIsSuppressedAndUserWarningsRemain() async throws {
		let host = Host([Execution([err("session_heartbeat tick\nUser warning\n"), .terminated(status: 0, timedOut: false)])])
		let results = try await collect(client(host))
		XCTAssertEqual(results.map(\.type), ["system", "message_stop"]); XCTAssertEqual(results[0].text, "User warning")
	}
	func testParserCorrelatesToolIDsAndSuppressesOnlyHostTrackedTools() {
		var parser = CodexExecEventParser(policy: policy)
		let start = parser.parseJSONLEvent(Data(#"{"type":"item.started","item":{"id":"item","type":"command_execution","command":"ls","status":"running"}}"#.utf8))
		let end = parser.parseJSONLEvent(Data(#"{"type":"item.completed","item":{"id":"item","type":"command_execution","command":"ls","exit_code":1}}"#.utf8))
		XCTAssertEqual(start?.toolInvocationID, end?.toolInvocationID); XCTAssertNotNil(start?.toolInvocationID)
		XCTAssertEqual(start?.toolIsError, false); XCTAssertEqual(end?.toolIsError, true)
		XCTAssertNil(parser.parseJSONLEvent(Data(#"{"type":"item.completed","item":{"id":"i","type":"function_call","name":"mcp__fixture__read_file"}}"#.utf8)))
		XCTAssertNotNil(parser.parseJSONLEvent(Data(#"{"type":"item.completed","item":{"id":"i","type":"function_call","name":"mcp__other__read_file"}}"#.utf8)))
	}
	func testMalformedAndUnknownInputRetainsLegacyFallback() {
		var parser = CodexExecEventParser(policy: policy)
		XCTAssertNil(parser.parseJSONLEvent(Data("{bad".utf8)))
		XCTAssertNil(parser.parseJSONLEvent(Data(" \n".utf8)))
		XCTAssertEqual(parser.parseJSONLEvent(Data(#"{"type":"future","message":"notice"}"#.utf8))?.type, "system")
		XCTAssertEqual(parser.extractCLIErrorDetail(fromStdout: Data("plain\n{\"error\":\"structured\"}\n".utf8)), "structured")
	}
	func testDisposalCleansActiveExecutionBeforeRestart() async throws {
		let first = Execution([], hold: true); let second = Execution([out("{\"type\":\"done\"}\n")])
		let host = Host([first, second]); let cli = client(host)
		let stream = try await cli.streamAgentMessage(.init(userMessage: "first"), runID: nil)
		let consumer = Task { for try await _ in stream {} }
		for _ in 0..<200 { if await first.starts == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
		await cli.dispose(); _ = try? await consumer.value
		_ = try await collect(cli)
		let clean = await host.cleaned; XCTAssertEqual(clean.count, 2)
	}

	func testReplacementCleansPreviousAttemptAndRejectsLateObservation() async throws {
		let first = Execution([], hold: true); let second = Execution([], hold: true)
		let host = Host([first, second]); let cli = client(host)
		let oldStream = try await cli.streamAgentMessage(.init(userMessage: "first"), runID: nil)
		let oldConsumer = Task { for try await _ in oldStream {} }
		for _ in 0..<200 { if await first.starts == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
		let replacement = try await cli.streamAgentMessage(.init(userMessage: "second"), runID: nil)
		for _ in 0..<200 { if await second.starts == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
		await host.emitOldObservation()
		await second.send(out("{\"type\":\"done\"}\n"))
		var values: [AIStreamResult] = []
		for try await event in replacement { values.append(event) }
		_ = try? await oldConsumer.value
		XCTAssertEqual(values.map(\.type), ["message_stop"])
		let clean = await host.cleaned; XCTAssertEqual(clean.count, 2)
	}

	func testInvalidPolicyFailsBeforePreparationOrExecution() async {
		let host = Host([])
		let cli = CodexExecClient(host: .init(validate: { throw AIProviderError.invalidConfiguration(detail: "invalid policy") },
			prepare: { try await host.prepare($0) }, startObservation: { _, _ in }, cleanup: { await host.clean($0) },
			recordBrokenServer: { _ in }, modelUnavailableError: { AIProviderError.invalidConfiguration(detail: $0) }, diagnostics: { _ in }), toolPolicy: policy)
		do { _ = try await collect(cli); XCTFail("Expected validation failure") } catch { XCTAssertEqual(error.localizedDescription, "invalid policy") }
		let prepared = await host.prepared; XCTAssertEqual(prepared, 0)
	}
}
