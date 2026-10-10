import Foundation
import AIClientKit
import AgentRuntimeKit
import AgentHeadlessContracts

import AgentACPEvents

/// A host-created controller. Runtime protocol, launch/configuration policy,
/// authentication, and workspace permissions remain owned by that controller.
public struct ACPHeadlessControllerServices: Sendable {
    public let events: AsyncStream<ACPHeadlessRuntimeEvent>
    public let bootstrapAndConfigure: @Sendable () async throws -> Void
    public let prompt: @Sendable (HeadlessAgentMessage) async throws -> Void
    public let cancelPrompt: @Sendable () async -> Void
    public let shutdown: @Sendable () async -> Void
    public let respond: @Sendable (AgentApprovalRequestID, AgentApprovalDecision) async -> Void
    public let normalizeError: @Sendable (any Error) async -> any Error
    public init(events: AsyncStream<ACPHeadlessRuntimeEvent>,
        bootstrapAndConfigure: @escaping @Sendable () async throws -> Void,
        prompt: @escaping @Sendable (HeadlessAgentMessage) async throws -> Void,
        cancelPrompt: @escaping @Sendable () async -> Void,
        shutdown: @escaping @Sendable () async -> Void,
        respond: @escaping @Sendable (AgentApprovalRequestID, AgentApprovalDecision) async -> Void,
        normalizeError: @escaping @Sendable (any Error) async -> any Error) {
        self.events = events; self.bootstrapAndConfigure = bootstrapAndConfigure; self.prompt = prompt
        self.cancelPrompt = cancelPrompt; self.shutdown = shutdown; self.respond = respond; self.normalizeError = normalizeError
    }
}
