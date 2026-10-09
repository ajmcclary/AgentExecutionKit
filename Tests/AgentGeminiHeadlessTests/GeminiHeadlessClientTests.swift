import XCTest
import AIClientKit
import AgentCLIExecution
import AgentGeminiHeadless
import AgentHeadlessContracts

final class GeminiHeadlessClientTests: XCTestCase {
    private enum FixtureError: Error { case unexpected, preparation }
    private actor Execution: AgentCLIExecuting {
        let events: [AgentCLIRunner.StreamEvent]
        let hold: Bool
        let failure: AgentCLIExecutionError?
        var starts = 0; var cancellations = 0
        var arguments: [String] = []; var input: String?; var environment: [String: String] = [:]; var removed: Set<String> = []
        var continuation: AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.Continuation?
        init(_ events: [AgentCLIRunner.StreamEvent], hold: Bool = false, failure: AgentCLIExecutionError? = nil) {
            self.events = events; self.hold = hold; self.failure = failure
        }
        func run(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?, additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AgentCLIRunner.Result { throw FixtureError.unexpected }
        func runStreaming(args: [String], stdin: String?, outputMode: AgentCLIRunner.OutputFlagMode, timeout: TimeInterval?, additionalEnvironment: [String: String], additionalRemovedKeys: Set<String>) async throws -> AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error> {
            starts += 1; arguments = args; input = stdin; environment = additionalEnvironment; removed = additionalRemovedKeys
            if let failure { throw failure }
            let pair = AsyncThrowingStream<AgentCLIRunner.StreamEvent, Error>.makeStream()
            continuation = pair.continuation
            for event in events { pair.continuation.yield(event) }
            if !hold { pair.continuation.finish() }
            return pair.stream
        }
        func cancelAll() { cancellations += 1; continuation?.finish() }
        func send(_ event: AgentCLIRunner.StreamEvent) { continuation?.yield(event) }
    }
    private actor Host {
        var executions: [Execution]
        var prepared: [UUID] = []; var cleaned: [UUID] = []
        var resumeIDs: [String?] = []
        var observers: [@Sendable (AIStreamResult) -> Void] = []
        init(_ executions: [Execution]) { self.executions = executions }
        func prepare(_ message: HeadlessAgentMessage, _ id: UUID?) throws -> GeminiHeadlessRunContext {
            guard !executions.isEmpty else { throw FixtureError.preparation }
            let runID = id ?? UUID(); prepared.append(runID); resumeIDs.append(message.resumeSessionID)
            return .init(runID: runID, arguments: ["-p", "--resume", message.resumeSessionID ?? "none"], input: message.userMessage,
                         additionalEnvironment: ["HOST_CONFIG": "explicit"], additionalRemovedKeys: ["HOST_REMOVED"], execution: executions.removeFirst())
        }
        func observe(_ emit: @escaping @Sendable (AIStreamResult) -> Void) { observers.append(emit) }
        func emitOldObserver() { observers.first?(.init(type: "content", text: "stale")) }
        func clean(_ context: GeminiHeadlessRunContext) { cleaned.append(context.id) }
    }
    private func client(_ host: Host) -> GeminiHeadlessClient {
        .init(host: .init(prepare: { try await host.prepare($0, $1) }, startObservation: { _, emit in await host.observe(emit) },
                         cleanup: { await host.clean($0) }))
    }
    private func out(_ text: String) -> AgentCLIRunner.StreamEvent { .stdout(Data(text.utf8)) }
    private func err(_ text: String) -> AgentCLIRunner.StreamEvent { .stderr(Data(text.utf8)) }
    private func collect(_ cli: GeminiHeadlessClient, runID: UUID? = nil) async throws -> [AIStreamResult] {
        let provider: any HeadlessAgentProviding = cli
        var values: [AIStreamResult] = []
        for try await value in try await provider.streamAgentMessage(.init(systemPrompt: "system", userMessage: "user", resumeSessionID: " exact resume "), runID: runID) { values.append(value) }
        return values
    }
    private func waitForStart(_ execution: Execution) async throws {
        for _ in 0..<200 { if await execution.starts == 1 { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Fixture did not start"); throw FixtureError.unexpected
    }
    func testChunkedStreamingFinalAuthorityUsageAndSingleCompletion() async throws {
        let execution = Execution([out("{\"type\":\"mes"), out("sage\",\"role\":\"assistant\",\"content\":\"partial\"}\n"),
                                   out(#"{"type":"result","status":"success","session_id":"session","stats":{"input_tokens":3,"output_tokens":4}}"# + "\n"),
                                   out(#"{"type":"result","status":"success"}"#)])
        let host = Host([execution]); let values = try await collect(client(host))
        XCTAssertEqual(values.map(\.type), ["content", "message_stop"])
        XCTAssertEqual(values[1].providerSessionID, "session")
        XCTAssertEqual(values[1].promptTokens, 3); XCTAssertEqual(values[1].completionTokens, 4)
        let cleaned = await host.cleaned; XCTAssertEqual(cleaned.count, 1)
    }
    func testTrailingFinalResultDuplicateAndLaterFramesAreIgnored() async throws {
        let host = Host([Execution([out(#"[{"type":"result","status":"success"},{"type":"result","status":"success"},{"type":"message","role":"assistant","content":"late"}]"#)])])
        let values = try await collect(client(host))
        XCTAssertEqual(values.map(\.type), ["message_stop"])
    }
    func testCleanExitWithTrailingContentAddsOneCompletion() async throws {
        let host = Host([Execution([out(#"{"type":"message","role":"assistant","content":"tail"}"#), .terminated(status: 0, timedOut: false)])])
        let values = try await collect(client(host)); XCTAssertEqual(values.map(\.type), ["content", "message_stop"])
    }
    func testMissingTerminationFailsAndCleansContext() async {
        let host = Host([Execution([])])
        do { _ = try await collect(client(host)); XCTFail("Expected missing exit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not report a termination status")) }
        let cleaned = await host.cleaned; XCTAssertEqual(cleaned.count, 1)
    }
    func testHostInputsEnvironmentRemovalRunAndResumeIdentityArePreserved() async throws {
        let execution = Execution([.terminated(status: 0, timedOut: false)])
        let host = Host([execution]); let runID = UUID(); _ = try await collect(client(host), runID: runID)
        let args = await execution.arguments; let input = await execution.input
        let environment = await execution.environment; let removed = await execution.removed
        let prepared = await host.prepared; let resumeIDs = await host.resumeIDs
        XCTAssertEqual(args, ["-p", "--resume", " exact resume "]); XCTAssertEqual(input, "user")
        XCTAssertEqual(environment, ["HOST_CONFIG": "explicit"]); XCTAssertEqual(removed, ["HOST_REMOVED"])
        XCTAssertEqual(prepared, [runID]); XCTAssertEqual(resumeIDs, [" exact resume "])
    }
    func testStdoutErrorWinsOverStderrAndNoRetryOccurs() async {
        let host = Host([Execution([out("{\"message\":\"primary\"}\n"), err("unauthorized"), .terminated(status: 1, timedOut: false)])])
        do { _ = try await collect(client(host)); XCTFail("Expected error") } catch { XCTAssertEqual(error.localizedDescription, "primary") }
        let count = await host.prepared.count; XCTAssertEqual(count, 1)
    }
    func testTimeoutAuthenticationRateLimitOverloadAndUnknownFailuresKeepMessages() async {
        for (stderr, timeout, expected) in [("", true, "Gemini CLI timed out. Please retry shortly."),
                                           ("command not found", false, "Gemini CLI not found. Install it and ensure it is available on PATH."),
                                           ("login needed", false, "Gemini CLI not authenticated. Run `gemini login` in a terminal and try again."),
                                           ("too many requests", false, "Gemini CLI rate limited. Please wait and retry."),
                                           ("busy", false, "busy"),
                                           ("", false, "Gemini CLI exited with status 7"), ("other failure", false, "other failure")] {
            let host = Host([Execution([err(stderr), .terminated(status: 7, timedOut: timeout)])])
            do { _ = try await collect(client(host)); XCTFail("Expected failure") } catch { XCTAssertEqual(error.localizedDescription, expected) }
        }
    }
    func testLaunchErrorsMapAndCleanBeforeObservation() async {
        for (failure, expected) in [(AgentCLIExecutionError.commandNotFound("fixture"), "Gemini CLI not found (fixture). Install it and ensure it is available on PATH."), (.spawnFailed("spawn detail"), "spawn detail")] {
            let host = Host([Execution([], failure: failure)])
            do { _ = try await collect(client(host)); XCTFail("Expected failure") } catch { XCTAssertEqual(error.localizedDescription, expected) }
            let cleaned = await host.cleaned; let observers = await host.observers.count
            XCTAssertEqual(cleaned.count, 1); XCTAssertEqual(observers, 0)
        }
    }
    func testPrepareFailureDoesNotStartObservationOrFabricateCleanup() async {
        let host = Host([])
        do { _ = try await collect(client(host)); XCTFail("Expected preparation failure") } catch {}
        let cleaned = await host.cleaned; let observers = await host.observers.count
        XCTAssertTrue(cleaned.isEmpty); XCTAssertEqual(observers, 0)
    }
    func testStderrRemainsVisibleOnSuccessfulExit() async throws {
        let host = Host([Execution([err("warning\n"), .terminated(status: 0, timedOut: false)])])
        let values = try await collect(client(host)); XCTAssertEqual(values.map(\.type), ["system", "message_stop"]); XCTAssertEqual(values.first?.text, "warning")
    }
    func testDisposeWaitsForCleanupThenCanRestart() async throws {
        let first = Execution([], hold: true); let second = Execution([.terminated(status: 0, timedOut: false)])
        let host = Host([first, second]); let cli = client(host)
        let stream = try await cli.streamAgentMessage(.init(userMessage: "first"))
        let consumer = Task { for try await _ in stream {} }
        try await waitForStart(first); await cli.dispose(); _ = try await consumer.value
        _ = try await collect(cli)
        let clean = await host.cleaned; XCTAssertEqual(Set(clean).count, 2)
    }
    func testReplacementRejectsStaleObserverAndCleansBothRuns() async throws {
        let first = Execution([], hold: true); let second = Execution([], hold: true)
        let host = Host([first, second]); let cli = client(host)
        let old = try await cli.streamAgentMessage(.init(userMessage: "first"))
        let consumer = Task { for try await _ in old {} }; try await waitForStart(first)
        let replacement = try await cli.streamAgentMessage(.init(userMessage: "second")); try await waitForStart(second)
        await host.emitOldObserver(); await second.send(out("{\"type\":\"result\",\"status\":\"success\"}\n"))
        var values: [AIStreamResult] = []; for try await value in replacement { values.append(value) }
        _ = try await consumer.value
        XCTAssertEqual(values.map(\.type), ["message_stop"])
        let cleaned = await host.cleaned; XCTAssertEqual(Set(cleaned).count, 2)
    }
    func testConsumerCancellationStopsExecutionAndCleanupFinishes() async throws {
        let execution = Execution([], hold: true); let host = Host([execution]); let cli = client(host)
        let stream = try await cli.streamAgentMessage(.init(userMessage: "cancel"))
        let consumer = Task { for try await _ in stream {} }; try await waitForStart(execution)
        consumer.cancel(); _ = try? await consumer.value; await cli.dispose()
        let cleaned = await host.cleaned; let cancels = await execution.cancellations
        XCTAssertEqual(cleaned.count, 1); XCTAssertGreaterThanOrEqual(cancels, 1)
    }
    private actor PreparationBarrier {
        var continuation: CheckedContinuation<Void, Never>?
        var entered = false
        var cleaned = false
        func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
        func clean() { cleaned = true }
    }
    func testCancellationDuringPreparationCleansReturnedContextWithoutLaunching() async throws {
        let barrier = PreparationBarrier(); let execution = Execution([])
        let cli = GeminiHeadlessClient(host: .init(prepare: { message, runID in
            await barrier.wait()
            return .init(runID: runID ?? UUID(), arguments: [], input: message.userMessage, execution: execution)
        }, startObservation: { _, _ in XCTFail("Cancelled preparation must not observe") },
        cleanup: { _ in await barrier.clean() }))
        let stream = try await cli.streamAgentMessage(.init(userMessage: "cancel preparation"))
        let consumer = Task { for try await _ in stream {} }
        for _ in 0..<200 { if await barrier.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        consumer.cancel()
        await barrier.release()
        await cli.dispose(); _ = try? await consumer.value
        let starts = await execution.starts; let cleaned = await barrier.cleaned
        XCTAssertEqual(starts, 0); XCTAssertTrue(cleaned)
    }
    func testMalformedJSONAndRuntimeErrorsFailWithoutRetryAndCleanContext() async {
        for text in ["{bad\n", #"{"type":"result","status":"error","error":{"message":"runtime failure"}}"# + "\n"] {
            let host = Host([Execution([out(text)])])
            do { _ = try await collect(client(host)); XCTFail("Expected parser failure") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
            let prepared = await host.prepared; let cleaned = await host.cleaned
            XCTAssertEqual(prepared.count, 1); XCTAssertEqual(cleaned.count, 1)
        }
    }
    func testExit148KeepsProviderSpecificAPIError() async {
        let host = Host([Execution([.terminated(status: 148, timedOut: false)])])
        do { _ = try await collect(client(host)); XCTFail("Expected API error") }
        catch { XCTAssertEqual(error.localizedDescription, "Gemini CLI reported an API error (exit code 148).") }
    }

}
