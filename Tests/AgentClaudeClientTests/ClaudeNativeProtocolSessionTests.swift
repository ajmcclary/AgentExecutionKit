import XCTest
import Foundation
import Synchronization
import AgentClaudeClient
import AgentClaudeProtocol
import AgentClaudeControl
import AgentClaudePermissions
import AgentRuntimeKit

@MainActor
final class ClaudeNativeProtocolSessionTests: XCTestCase {
    private enum Failure: Error, Equatable { case write, closed }
    private typealias Session = ClaudeNativeProtocolSession
    private typealias Routing = Session.Routing<String>
    @MainActor private final class Host {
        let session: Session
        init(sleep: @escaping ClaudeControlChannel.Sleep = { try await Task.sleep(for: $0) }) { session = .init(requestIDPrefix: "host-", sleep: sleep) }
        func expire(_ ticket: Session.ControlTicket) { session.expire(ticket) }
    }
    private final class Clock: Sendable {
        let ticks = AsyncStream<Void>.makeStream()
        let durations = Mutex<[Duration]>([])
        func sleep(_ duration: Duration) async throws {
            durations.withLock { $0.append(duration) }
            for await _ in ticks.stream { return }
            throw CancellationError()
        }
    }
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        XCTAssertTrue(condition(), "Condition did not become ready")
    }
    private func request(_ id: String = "permission", subtype: String = "can_use_tool", command: String = "original") throws -> ClaudeNativeProtocolCodec.ControlRequest {
        .init(requestID: id, request: try .init(object: ["subtype": subtype, "tool_name": "Bash", "input": ["command": command]]), subtype: subtype)
    }
    private func approval(_ id: String) -> AgentApprovalRequest {
        .init(requestID: .claudeControl(id), method: "control/can_use_tool", kind: .commandExecution, threadID: "thread", turnID: "turn", itemID: id)
    }
    private func routing(stream: @escaping (ClaudeProtocolJSONObject) -> Void = { _ in },
            policy: @escaping (ClaudeNativeProtocolCodec.ControlRequest) -> Session.PolicyDecision<String> = { _ in .init(.allowOnce) },
            write: @escaping (Data) throws -> Void = { _ in }, observe: @escaping (Session.Observation<String>) -> Void = { _ in },
            cancelled: @escaping (String) -> Void = { _ in },
            failed: @escaping (ClaudeNativeProtocolCodec.ControlRequest, String?, any Error) -> Void = { _, _, _ in XCTFail() }) -> Routing {
        .init(stream: stream, policy: policy, write: write, observe: observe, approvalCancelled: cancelled, requestFailed: failed)
    }
    private func response(_ id: String, subtype: String = "success", pending: [[String: Any]] = []) throws -> ClaudeNativeProtocolCodec.InboundMessage {
        let data = try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": ["request_id": id,
            "subtype": subtype, "error": "refused", "response": ["ok": true], "pending_permission_requests": pending]])
        return try XCTUnwrap(ClaudeNativeProtocolCodec.decodeLine(data))
    }
    private func start(_ host: Host, timeout: TimeInterval? = nil, observe: @escaping (Session.ControlTicket, Bool) -> Void = { _, _ in },
                       write: @escaping (Data) throws -> Void = { _ in }) -> Task<ClaudeProtocolJSONObject, any Error> {
        Task { try await host.session.request(.init(object: ["subtype": "initialize"]), timeoutSeconds: timeout,
            onExpiry: { [weak host] ticket in await host?.expire(ticket) }, isAvailable: { true }, observe: observe, write: write) }
    }
    func testUserMessageRegistersTurnOnlyAfterSuccessfulWriteAndKeepsWireFields() throws {
        let session = Session(requestIDPrefix: "host-"); let turn = UUID(); var order: [String] = []
        let result = try session.sendUserMessage("hello", sessionID: "session", isAvailable: { true }, write: { data in
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(value["session_id"] as? String, "session"); XCTAssertEqual(value["type"] as? String, "user")
            order.append("write")
        }, openTurn: { order.append("turn"); return turn })
        XCTAssertEqual(result, turn); XCTAssertEqual(order, ["write", "turn"])
        XCTAssertThrowsError(try session.sendUserMessage("hello", sessionID: nil, isAvailable: { true }, write: { _ in throw Failure.write }, openTurn: { XCTFail(); return UUID() })) { XCTAssertEqual($0 as? Failure, .write) }
        XCTAssertThrowsError(try session.sendUserMessage("hello", sessionID: nil, isAvailable: { false }, write: { _ in XCTFail() }, openTurn: { XCTFail(); return UUID() })) { XCTAssertEqual($0 as? ClaudeNativeClientError, .processNotRunning) }
    }
    func testInboundObservationPrecedesStreamAndKeepaliveHasNoOtherEffects() throws {
        let host = Host(); var order: [String] = []; let object = try ClaudeProtocolJSONObject(object: ["future": "value"])
        let ports = routing(stream: { XCTAssertEqual($0, object); order.append("stream") }, policy: { _ in XCTFail(); return .init(.allowOnce) }, write: { _ in XCTFail() }, observe: { if case .inbound = $0 { order.append("inbound") } else { XCTFail() } })
        host.session.route(.streamPayload(object), routing: ports); host.session.route(.keepAlive, routing: ports)
        XCTAssertEqual(order, ["inbound", "stream", "inbound"])
    }
    func testRPCRetainsPrefixRegistersBeforeWriteAndMatchesOnlyOnce() async throws {
        let host = Host(); var order: [String] = []; var id = ""
        let ports = routing(observe: { switch $0 { case .inbound: order.append("inbound"); case .responseReceived: order.append("response"); default: XCTFail() } })
        let task = start(host, observe: { ticket, expects in
            id = ticket.requestID; XCTAssertTrue(id.hasPrefix("host-")); XCTAssertTrue(expects)
            XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty); order.append("sent")
        }, write: { _ in XCTAssertEqual(host.session.pendingControlRequestIDs, [id]); order.append("write") })
        await wait { !host.session.pendingControlRequestIDs.isEmpty }
        let reply = try response(id); host.session.route(reply, routing: ports)
        XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty)
        let result = try await task.value; XCTAssertEqual(try result.dictionary()["ok"] as? Bool, true)
        host.session.route(reply, routing: ports)
        XCTAssertEqual(order, ["sent", "write", "inbound", "response", "inbound"])
    }
    func testErrorRecoveryUsesRequestPathWithoutInventingInboundFrames() async throws {
        let host = Host(); var order: [String] = []
        let task = start(host); await wait { !host.session.pendingControlRequestIDs.isEmpty }
        let id = try XCTUnwrap(host.session.pendingControlRequestIDs.first)
        let ports = routing(policy: { request in order.append("policy"); return .init(.present(self.approval(request.requestID)), context: "recovery") }, observe: {
            switch $0 {
            case .inbound: order.append("inbound")
            case .responseReceived: XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty); order.append("response")
            case .requestReceived: order.append("request")
            case .permission(_, .requested, let context): XCTAssertEqual(context, "recovery"); order.append("approval")
            default: XCTFail()
            }
        })
        host.session.route(try response(id, subtype: "error", pending: [["request_id": "recover", "request": ["subtype": "can_use_tool"]]]), routing: ports)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? ClaudeNativeClientError, .invalidControlResponse("refused")) }
        XCTAssertEqual(order, ["inbound", "response", "request", "policy", "approval"]); XCTAssertEqual(host.session.pendingPermissionRequestIDs, ["recover"])
    }
    func testUnmatchedErrorNeverRecoversPermissionsOrObservesMatchedResponse() throws {
        let host = Host(); var inbound = 0
        host.session.route(try response("unknown", subtype: "error", pending: [["request_id": "recover", "request": ["subtype": "can_use_tool"]]]), routing: routing(policy: { _ in XCTFail(); return .init(.allowOnce) }, observe: {
            if case .inbound = $0 { inbound += 1 } else { XCTFail() }
        }))
        XCTAssertEqual(inbound, 1); XCTAssertTrue(host.session.pendingPermissionRequestIDs.isEmpty)
    }
    func testDuplicatePermissionKeepsCapturedInputAndPolicyContextIsLocal() async throws {
        let host = Host(); var policyCalls = 0; var contexts: [String] = []; var bytes: [Data] = []
        let ports = routing(policy: { request in policyCalls += 1; return .init(.present(self.approval(request.requestID)), context: request.requestID) }, observe: {
            if case .permission(_, .requested, let context) = $0 { contexts.append(context ?? "nil") }
        })
        host.session.route(.controlRequest(try request("same")), routing: ports)
        host.session.route(.controlRequest(try request("same", command: "changed")), routing: ports)
        host.session.route(.controlRequest(try request("other")), routing: ports)
        XCTAssertEqual(policyCalls, 2); XCTAssertEqual(contexts, ["same", "other"])
        await host.session.respondPermission(id: "same", decision: .accept, write: { bytes.append($0) }, observe: { _ in }, failure: { _ in XCTFail() })
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bytes.first)) as? [String: Any])
        let reply = try XCTUnwrap(wire["response"] as? [String: Any]); let result = try XCTUnwrap(reply["response"] as? [String: Any])
        XCTAssertEqual((result["updatedInput"] as? [String: Any])?["command"] as? String, "original")
        XCTAssertEqual(host.session.pendingPermissionRequestIDs, ["other"])
    }
    func testAutomaticAndUnsupportedWriteFailuresRetainPerRequestContext() throws {
        let host = Host(); var policyCalls = 0; var failures: [String?] = []
        let ports = routing(policy: { _ in policyCalls += 1; return .init(.allowOnce, context: "host-match") }, write: { _ in throw Failure.write }, failed: { request, context, error in
            XCTAssertEqual(error as? Failure, .write); failures.append(context)
            if request.subtype != "can_use_tool" { XCTAssertNil(context) }
        })
        host.session.receiveRequest(try request(), routing: ports)
        host.session.receiveRequest(try request("unsupported", subtype: "future"), routing: ports)
        XCTAssertEqual(policyCalls, 1); XCTAssertEqual(failures.count, 2); XCTAssertEqual(failures[0], "host-match"); XCTAssertNil(failures[1])
    }
    func testCancellationOnlyCancelsPendingApprovalOnceAndWritesNoReply() throws {
        let host = Host(); var cancelled: [String] = []; var observations = 0
        let ports = routing(policy: { .init(.present(self.approval($0.requestID))) }, write: { _ in XCTFail() }, observe: { if case .requestCancelled = $0 { observations += 1 } }, cancelled: { cancelled.append($0) })
        host.session.route(.controlRequest(try request()), routing: ports)
        host.session.route(.controlCancelRequest(requestID: "unknown"), routing: ports)
        host.session.route(.controlCancelRequest(requestID: "permission"), routing: ports)
        host.session.route(.controlCancelRequest(requestID: "permission"), routing: ports)
        XCTAssertEqual(cancelled, ["permission"]); XCTAssertEqual(observations, 3); XCTAssertTrue(host.session.pendingPermissionRequestIDs.isEmpty)
    }
    func testRetiredScopeRefusesRequestsAndDecisionsThenBeginScopeAllowsIDReuse() async throws {
        let host = Host(); var approvals = 0; var writes = 0
        let ports = routing(policy: { .init(.present(self.approval($0.requestID))) }, observe: { if case .permission(_, .requested, _) = $0 { approvals += 1 } })
        host.session.receiveRequest(try request(), routing: ports); host.session.retirePermissions()
        host.session.receiveRequest(try request(), routing: ports)
        await host.session.respondPermission(id: "permission", decision: .accept, write: { _ in writes += 1 }, observe: { _ in XCTFail() }, failure: { _ in XCTFail() })
        XCTAssertEqual(approvals, 1); XCTAssertEqual(writes, 0)
        host.session.beginScope(); host.session.receiveRequest(try request(), routing: ports)
        XCTAssertEqual(approvals, 2); XCTAssertEqual(host.session.pendingPermissionRequestIDs, ["permission"])
    }
    func testPermissionDecisionFailureAwaitsHostFailureEffectAndRetiresTicket() async throws {
        let host = Host(); var order: [String] = []
        host.session.receiveRequest(try request(), routing: routing(policy: { .init(.present(self.approval($0.requestID))) }))
        await host.session.respondPermission(id: "permission", decision: .decline, write: { _ in order.append("write"); throw Failure.write }, observe: { _ in order.append("observe") }, failure: {
            XCTAssertEqual($0 as? Failure, .write); XCTAssertTrue(host.session.pendingPermissionRequestIDs.isEmpty)
            await Task.yield(); order.append("failure")
        })
        XCTAssertEqual(order, ["observe", "write", "failure"])
    }
    func testNonPositiveOrAbsentDeadlineRemainsUnboundedUntilTransportFailure() async throws {
        for timeout in [nil, 0, -1] as [Double?] {
            let clock = Clock(); let host = Host(sleep: clock.sleep); let task = start(host, timeout: timeout)
            await wait { !host.session.pendingControlRequestIDs.isEmpty }
            task.cancel(); await Task.yield(); XCTAssertFalse(host.session.pendingControlRequestIDs.isEmpty)
            XCTAssertTrue(clock.durations.withLock { $0.isEmpty })
            host.session.failAll(with: Failure.closed)
            do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? Failure, .closed) }
            XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty)
        }
    }
    func testPositiveDeadlineDeliversExpiryOnOwnerAndKeepsNativeTimeoutError() async throws {
        let clock = Clock(); let host = Host(sleep: clock.sleep); let task = start(host, timeout: 2)
        await wait { !host.session.pendingControlRequestIDs.isEmpty && !clock.durations.withLock { $0.isEmpty } }
        let id = try XCTUnwrap(host.session.pendingControlRequestIDs.first)
        XCTAssertEqual(clock.durations.withLock { $0 }, [.seconds(2)])
        clock.ticks.continuation.yield(())
        do { _ = try await task.value; XCTFail() } catch { XCTAssertEqual(error as? ClaudeNativeClientError, .controlRequestTimedOut(requestID: id)) }
        XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty)
    }
    func testNotificationHasNoPendingRPCAndUnavailableRequestsHaveNoEffects() async throws {
        let host = Host(); let object = try ClaudeProtocolJSONObject(object: ["subtype": "future"]); var writes = 0
        try host.session.notify(object, isAvailable: { true }, observe: { _, expects in XCTAssertFalse(expects) }, write: { _ in writes += 1 })
        XCTAssertEqual(writes, 1); XCTAssertTrue(host.session.pendingControlRequestIDs.isEmpty)
        do { _ = try await host.session.request(object, timeoutSeconds: nil, onExpiry: { _ in XCTFail() }, isAvailable: { false }, observe: { _, _ in XCTFail() }, write: { _ in XCTFail() }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeNativeClientError, .processNotRunning) }
        XCTAssertThrowsError(try host.session.notify(object, isAvailable: { false }, observe: { _, _ in XCTFail() }, write: { _ in XCTFail() })) { XCTAssertEqual($0 as? ClaudeNativeClientError, .processNotRunning) }
    }
}
