import Foundation
import AgentRuntimeKit
import AgentClaudeProtocol
import AgentClaudeControl
import AgentClaudePermissions

/// Caller-actor-owned native control plane. Routing, RPC bookkeeping and permission
/// scope have one owner. Hosts supply transport, approval policy/presentation and
/// diagnostics; no inventory, authorization policy or settings are inferred.
public final class ClaudeNativeProtocolSession {
    public typealias ControlTicket = ClaudeControlChannel.Ticket
    private let channel: ClaudeControlChannel
    private let permissions = ClaudePermissionEngine()
    public init(requestIDPrefix: String, sleep: @escaping ClaudeControlChannel.Sleep = { try await Task.sleep(for: $0) }) {
        channel = .init(requestIDPrefix: requestIDPrefix, errors: .init(
            unavailable: { ClaudeNativeClientError.processNotRunning },
            invalidResponse: { ClaudeNativeClientError.invalidControlResponse($0) },
            timedOut: { ClaudeNativeClientError.controlRequestTimedOut(requestID: $0) }), sleep: sleep)
    }
    public var pendingControlRequestIDs: [String] { channel.pendingRequestIDs }
    public var pendingPermissionRequestIDs: [String] { permissions.pendingRequestIDs }
    public func beginScope() { permissions.beginScope() }
    public func retirePermissions() { permissions.retire() }
    public func failAll(with error: any Error) { channel.failAll(with: error) }
    public func expire(_ ticket: ControlTicket) { channel.expire(ticket) }

    public func request(_ request: ClaudeProtocolJSONObject, timeoutSeconds: TimeInterval?,
            onExpiry: @escaping @Sendable (ControlTicket) async -> Void, isAvailable: () -> Bool,
            observe: (ControlTicket, Bool) -> Void, write: (Data) throws -> Void,
            isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeProtocolJSONObject {
        let deadline: ClaudeControlChannel.Deadline?
        if let seconds = timeoutSeconds, seconds > 0 { deadline = .init(duration: .seconds(seconds), onExpiry: onExpiry) }
        else { deadline = nil }
        return try await channel.request(request, deadline: deadline, isAvailable: isAvailable, observe: observe, write: write)
    }
    public func notify(_ request: ClaudeProtocolJSONObject, isAvailable: () -> Bool,
                       observe: (ControlTicket, Bool) -> Void, write: (Data) throws -> Void) throws {
        try channel.notify(request, isAvailable: isAvailable, observe: observe, write: write)
    }
    public func sendUserMessage(_ text: String, sessionID: String?, isAvailable: () -> Bool,
                               write: (Data) throws -> Void, openTurn: () -> UUID) throws -> UUID {
        guard isAvailable() else { throw ClaudeNativeClientError.processNotRunning }
        let payload = try ClaudeNativeProtocolCodec.encodeUserMessage(text: text, sessionID: sessionID)
        try write(payload)
        return openTurn()
    }

    public struct PolicyDecision<Context> {
        public let disposition: ClaudePermissionEngine.Disposition
        public let context: Context?
        public init(_ disposition: ClaudePermissionEngine.Disposition, context: Context? = nil) {
            self.disposition = disposition; self.context = context
        }
    }
    public enum Observation<Context> {
        case inbound(ClaudeNativeProtocolCodec.InboundMessage)
        case requestReceived(ClaudeNativeProtocolCodec.ControlRequest)
        case responseReceived(ClaudeNativeProtocolCodec.ControlResponse)
        case requestCancelled(String)
        case permission(ClaudeNativeProtocolCodec.ControlRequest, ClaudePermissionEngine.Event, Context?)
    }
    public struct Routing<Context> {
        public let stream: (ClaudeProtocolJSONObject) -> Void
        public let policy: (ClaudeNativeProtocolCodec.ControlRequest) -> PolicyDecision<Context>
        public let write: (Data) throws -> Void
        public let observe: (Observation<Context>) -> Void
        public let approvalCancelled: (String) -> Void
        public let requestFailed: (ClaudeNativeProtocolCodec.ControlRequest, Context?, any Error) -> Void
        public init(stream: @escaping (ClaudeProtocolJSONObject) -> Void,
                    policy: @escaping (ClaudeNativeProtocolCodec.ControlRequest) -> PolicyDecision<Context>,
                    write: @escaping (Data) throws -> Void, observe: @escaping (Observation<Context>) -> Void,
                    approvalCancelled: @escaping (String) -> Void,
                    requestFailed: @escaping (ClaudeNativeProtocolCodec.ControlRequest, Context?, any Error) -> Void) {
            self.stream = stream; self.policy = policy; self.write = write; self.observe = observe
            self.approvalCancelled = approvalCancelled; self.requestFailed = requestFailed
        }
    }
    public func route<Context>(_ inbound: ClaudeNativeProtocolCodec.InboundMessage, routing: Routing<Context>) {
        routing.observe(.inbound(inbound))
        switch inbound {
        case .streamPayload(let object): routing.stream(object)
        case .controlRequest(let request): receiveRequest(request, routing: routing)
        case .controlResponse(let response):
            channel.receive(response, observe: { routing.observe(.responseReceived($0)) },
                recoverPermission: { receiveRequest($0, routing: routing) })
        case .controlCancelRequest(let id):
            routing.observe(.requestCancelled(id))
            if let ticket = permissions.ticket(for: id), permissions.cancel(ticket) { routing.approvalCancelled(id) }
        case .keepAlive: break
        }
    }
    /// Recovered permissions enter the same request path, without inventing a new
    /// inbound-frame observation. Context is local to one policy evaluation/reply.
    public func receiveRequest<Context>(_ request: ClaudeNativeProtocolCodec.ControlRequest, routing: Routing<Context>) {
        routing.observe(.requestReceived(request))
        var context: Context?
        do {
            try permissions.receive(request, policy: { value in
                let decision = routing.policy(value); context = decision.context; return decision.disposition
            }, write: routing.write, observe: { routing.observe(.permission(request, $0, context)) })
        } catch { routing.requestFailed(request, context, error) }
    }
    public func respondPermission(id: String, decision: AgentApprovalDecision, write: (Data) throws -> Void,
            observe: (ClaudePermissionEngine.Event) -> Void, failure: (any Error) async -> Void,
            isolation: isolated (any Actor)? = #isolation) async {
        guard let ticket = permissions.ticket(for: id) else { return }
        do { try permissions.respond(ticket, decision: decision, write: write, observe: observe) }
        catch { await failure(error) }
    }
}
