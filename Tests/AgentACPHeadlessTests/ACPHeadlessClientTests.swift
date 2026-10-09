import XCTest
import Foundation
import AIClientKit
import AgentRuntimeKit
import AgentHeadlessContracts
import AgentACPHeadless

final class ACPHeadlessClientTests: XCTestCase {
    private actor Controller {
        let pair = AsyncStream<ACPHeadlessRuntimeEvent>.makeStream()
        let events: [ACPHeadlessRuntimeEvent]
        let hold: Bool
        let bootstrapFails: Bool
        var prompts = 0; var cancels = 0; var shutdowns = 0
        var decisions: [AgentApprovalDecision] = []
        var ids: [AgentApprovalRequestID] = []
        var message: HeadlessAgentMessage?
        var promptWaiter: CheckedContinuation<Void, Never>?
        init(events: [ACPHeadlessRuntimeEvent], hold: Bool = false, bootstrapFails: Bool = false) {
            self.events = events; self.hold = hold; self.bootstrapFails = bootstrapFails
        }
        func bootstrap() throws { if bootstrapFails { throw FixtureError.bootstrap } }
        func prompt(_ value: HeadlessAgentMessage) async {
            prompts += 1; message = value
            for event in events { pair.continuation.yield(event) }
            if hold { await withCheckedContinuation { promptWaiter = $0 } }
        }
        func cancel() { cancels += 1; promptWaiter?.resume(); promptWaiter = nil }
        func shutdown() { shutdowns += 1; pair.continuation.finish() }
        func respond(_ id: AgentApprovalRequestID, _ decision: AgentApprovalDecision) { ids.append(id); decisions.append(decision) }
        func services() -> ACPHeadlessControllerServices {
            .init(events: pair.stream, bootstrapAndConfigure: { try await self.bootstrap() },
                  prompt: { await self.prompt($0) }, cancelPrompt: { await self.cancel() }, shutdown: { await self.shutdown() },
                  respond: { await self.respond($0, $1) }, normalizeError: { _ in AIProviderError.invalidConfiguration(detail: "normalized host failure") })
        }
        func send(_ event: ACPHeadlessRuntimeEvent) { pair.continuation.yield(event) }
    }
    private enum FixtureError: Error { case bootstrap }
    private func client(_ controller: Controller, policy: ACPHeadlessClient.ApprovalPolicy = .declineUnsupported) -> ACPHeadlessClient {
        .init(providerName: "Fixture", prepare: { _, _ in await controller.services() }, approvalPolicy: policy)
    }
    private func collect(_ client: ACPHeadlessClient) async throws -> [AIStreamResult] {
        var values: [AIStreamResult] = []
        for try await value in try await client.streamAgentMessage(.init(systemPrompt: "system", userMessage: "user", resumeSessionID: " raw-id ")) { values.append(value) }
        return values
    }
    private func waitForPrompt(_ controller: Controller) async throws {
        for _ in 0..<200 { if await controller.prompts > 0 { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Fixture did not prompt")
    }
    func testSuccessPreservesEventsMessageIdentityAndOneShutdown() async throws {
        let controller = Controller(events: [.stream(.init(type: "content", text: "hello")), .stream(.init(type: "message_stop", text: nil)), .stream(.init(type: "message_stop", text: nil)), .terminal(state: .completed, errorText: nil)])
        let values = try await collect(client(controller))
        XCTAssertEqual(values.map(\.type), ["content", "message_stop"])
        let message = await controller.message; let shutdowns = await controller.shutdowns
        XCTAssertEqual(message?.resumeSessionID, " raw-id "); XCTAssertEqual(message?.systemPrompt, "system"); XCTAssertEqual(shutdowns, 1)
    }
    func testFailedTerminalPreservesProviderMessage() async {
        let controller = Controller(events: [.terminal(state: .failed, errorText: "terminal")])
        do { _ = try await collect(client(controller)); XCTFail("Expected error") }
        catch { XCTAssertEqual(error.localizedDescription, "terminal") }
        let shutdowns = await controller.shutdowns; XCTAssertEqual(shutdowns, 1)
    }
    func testBootstrapFailureCleansBeforeReturningNormalizedError() async {
        let controller = Controller(events: [], bootstrapFails: true)
        do { _ = try await collect(client(controller)); XCTFail("Expected bootstrap error") }
        catch { XCTAssertEqual(error.localizedDescription, "normalized host failure") }
        let shutdowns = await controller.shutdowns; let prompts = await controller.prompts
        XCTAssertEqual(shutdowns, 1); XCTAssertEqual(prompts, 0)
    }
    func testPreparationFailureUsesExplicitHostErrorWithoutController() async {
        let cli = ACPHeadlessClient(providerName: "Fixture", prepare: { _, _ in throw AIProviderError.invalidConfiguration(detail: "unsupported") }, approvalPolicy: .declineUnsupported)
        do { _ = try await collect(cli); XCTFail("Expected preparation error") }
        catch { XCTAssertEqual(error.localizedDescription, "unsupported") }
    }
    func testDeclinedApprovalRetainsExactIDAndMessageAndCancelsPrompt() async {
        let request = AgentApprovalRequest(requestID: .acp(" raw-request "), method: "session/request_permission", kind: .commandExecution, threadID: "session", turnID: "turn", itemID: "item", reason: " reason ")
        let controller = Controller(events: [.approvalRequested(request)], hold: true); let cli = client(controller)
        do { _ = try await collect(cli); XCTFail("Expected headless approval denial") }
        catch { XCTAssertEqual(error.localizedDescription, "Fixture requested tool approval during headless discovery: reason") }
        await cli.dispose()
        let ids = await controller.ids; let decisions = await controller.decisions
        XCTAssertEqual(ids, [.acp(" raw-request ")]); XCTAssertEqual(decisions, [.decline])
    }
    func testAcceptedApprovalUsesSessionDecision() async throws {
        let request = AgentApprovalRequest(requestID: .acp("id"), method: "session/request_permission", kind: .commandExecution, threadID: "session", turnID: "turn", itemID: "item")
        let controller = Controller(events: [.approvalRequested(request), .approvalResolved(request.requestID), .approvalCancelled(request.requestID)])
        _ = try await collect(client(controller, policy: .acceptForSession))
        let decisions = await controller.decisions; XCTAssertEqual(decisions, [.acceptForSession])
    }
    func testConcurrentDisposeSharesShutdownAndWaitsForRetiredRun() async throws {
        let controller = Controller(events: [], hold: true); let cli = client(controller)
        let stream = try await cli.streamAgentMessage(.init(userMessage: "hold")); let consumer = Task { for try await _ in stream {} }
        try await waitForPrompt(controller)
        await withTaskGroup(of: Void.self) { group in for _ in 0..<20 { group.addTask { await cli.dispose() } } }
        _ = try? await consumer.value
        let shutdowns = await controller.shutdowns; XCTAssertEqual(shutdowns, 1)
    }
    func testReplacementAndOldConsumerCancellationDoNotDisposeNewRun() async throws {
        let first = Controller(events: [], hold: true); let second = Controller(events: [], hold: true)
        actor Factory {
            var controllers: [Controller]
            init(_ values: [Controller]) { controllers = values }
            func next() async -> ACPHeadlessControllerServices { await controllers.removeFirst().services() }
        }
        let factory = Factory([first, second])
        let cli = ACPHeadlessClient(providerName: "Fixture", prepare: { _, _ in await factory.next() }, approvalPolicy: .declineUnsupported)
        let old = try await cli.streamAgentMessage(.init(userMessage: "first")); let oldConsumer = Task { for try await _ in old {} }
        try await waitForPrompt(first)
        let new = try await cli.streamAgentMessage(.init(userMessage: "second")); try await waitForPrompt(second)
        oldConsumer.cancel(); await first.send(.stream(.init(type: "content", text: "stale")))
        await second.send(.stream(.init(type: "content", text: "fresh"))); await second.cancel()
        var values: [AIStreamResult] = []; for try await value in new { values.append(value) }
        XCTAssertEqual(values.compactMap(\.text), ["fresh"])
        let shutdowns = await second.shutdowns; XCTAssertEqual(shutdowns, 1)
    }
}
