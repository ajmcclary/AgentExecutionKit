import Foundation
import AgentNativeProcessTransport
import ClaudeRuntimeKit

public struct ClaudeExpectedAgentPIDRegistrar: Sendable {
    public let register: @Sendable (Int32, String, UUID) async -> Void
    public let clear: @Sendable (Int32, String, UUID) async -> Void
    public init(register: @escaping @Sendable (Int32, String, UUID) async -> Void,
                clear: @escaping @Sendable (Int32, String, UUID) async -> Void) {
        self.register = register; self.clear = clear
    }
}
public struct ClaudeNativeRuntimePreparer: Sendable {
    public let isMCPServerRunning: @Sendable () async -> Bool
    public let prepareConfigFile: @Sendable () async throws -> URL?
    public let cleanupConfigFile: @Sendable (URL) async -> Void
    public init(isMCPServerRunning: @escaping @Sendable () async -> Bool,
                prepareConfigFile: @escaping @Sendable () async throws -> URL?, cleanupConfigFile: @escaping @Sendable (URL) async -> Void) {
        self.isMCPServerRunning = isMCPServerRunning; self.prepareConfigFile = prepareConfigFile; self.cleanupConfigFile = cleanupConfigFile
    }
}
public enum ClaudeNativeInterruptOutcome: Equatable, Sendable { case acknowledged, noTurnInFlight, timedOut, failed }

/// Caller-owned client lifecycle. Every mutable access and callback runs under
/// one host actor; child reaping uses a Sendable lease and host callback. No
/// process, config-file, registration, logging or event policy is implicit.
public final class ClaudeNativeClientLifecycle {
    public private(set) var configURL: URL?
    public private(set) var isShuttingDown = false
    private var registeredPID: Int32?
    private var teardown: (id: UUID, task: Task<Void, Never>)?
    public init() {}
    public func beginStart() { isShuttingDown = false }
    @_spi(Testing) public func setConfigURLForTesting(_ url: URL?) { configURL = url }
    public func prepareRuntime(preparer: ClaudeNativeRuntimePreparer,
            unavailable: @Sendable () -> any Error, isolation: isolated (any Actor)? = #isolation) async throws {
        if configURL != nil { return }
        guard await preparer.isMCPServerRunning() else { throw unavailable() }
        configURL = try await preparer.prepareConfigFile()
    }
    public func awaitTransportTeardown(isolation: isolated (any Actor)? = #isolation) async {
        if let teardown { await teardown.task.value }
    }
    public func tearDownTransport(invalidate: () -> AgentNativeProcessTransport.TerminationLease?,
            clearRegistration: @escaping @Sendable () async -> Void, isolation: isolated (any Actor)? = #isolation) async {
        if let teardown { await teardown.task.value; return }
        let id = UUID()
        let lease = invalidate()
        let task = Task { await lease?.finish(); await clearRegistration() }
        teardown = (id, task)
        await task.value
        if teardown?.id == id { teardown = nil }
    }
    public func registerPID(_ pid: Int32, clientName: String?, runID: UUID,
            registrar: ClaudeExpectedAgentPIDRegistrar, generation: () -> UInt64,
            registered: () -> Void, isolation: isolated (any Actor)? = #isolation) async {
        guard let clientName else { return }
        let capturedGeneration = generation()
        registeredPID = pid
        await registrar.register(pid, clientName, runID)
        if isShuttingDown || capturedGeneration != generation() {
            await registrar.clear(pid, clientName, runID)
            if registeredPID == pid { registeredPID = nil }
            return
        }
        registered()
    }
    public func clearPID(clientName: String?, runID: UUID,
            registrar: ClaudeExpectedAgentPIDRegistrar, cleared: () -> Void,
            isolation: isolated (any Actor)? = #isolation) async {
        guard let registeredPID, let clientName else { return }
        self.registeredPID = nil
        await registrar.clear(registeredPID, clientName, runID)
        cleared()
    }
    public struct StartActions<Reference: Sendable> {
        public let isReady: () -> Bool
        public let reference: () -> Reference
        public let ensureEvents: () -> Void
        public let observeStart: () -> Void
        public let prepare: () async throws -> Void
        public let spawn: () async throws -> Void
        public let initialize: () async throws -> Void
        public let hasProcess: () -> Bool
        public let shutdown: () async -> Void
        public init(isReady: @escaping () -> Bool, reference: @escaping () -> Reference,
                    ensureEvents: @escaping () -> Void, observeStart: @escaping () -> Void,
                    prepare: @escaping () async throws -> Void, spawn: @escaping () async throws -> Void,
                    initialize: @escaping () async throws -> Void, hasProcess: @escaping () -> Bool,
                    shutdown: @escaping () async -> Void) {
            self.isReady = isReady; self.reference = reference; self.ensureEvents = ensureEvents; self.observeStart = observeStart
            self.prepare = prepare; self.spawn = spawn; self.initialize = initialize; self.hasProcess = hasProcess; self.shutdown = shutdown
        }
    }
    public func startOrResume<Reference: Sendable>(actions: StartActions<Reference>, isolation: isolated (any Actor)? = #isolation) async throws -> Reference {
        if actions.isReady() { return actions.reference() }
        actions.ensureEvents(); beginStart(); actions.observeStart()
        do {
            try await actions.prepare(); try await actions.spawn(); try await actions.initialize()
            return actions.reference()
        } catch {
            if actions.hasProcess() || configURL != nil { await actions.shutdown() }
            throw error
        }
    }
    public struct ShutdownActions {
        public let prepare: () -> Void
        public let teardownTransport: () async -> Void
        public let retireEpoch: () -> Void
        public let finish: () -> Void
        public init(prepare: @escaping () -> Void, teardownTransport: @escaping () async -> Void,
                    retireEpoch: @escaping () -> Void, finish: @escaping () -> Void) {
            self.prepare = prepare; self.teardownTransport = teardownTransport; self.retireEpoch = retireEpoch; self.finish = finish
        }
    }
    public func shutdown(actions: ShutdownActions, preparer: ClaudeNativeRuntimePreparer,
            isolation: isolated (any Actor)? = #isolation) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        actions.prepare()
        await actions.teardownTransport()
        actions.retireEpoch()
        if let configURL { await preparer.cleanupConfigFile(configURL); self.configURL = nil }
        actions.finish()
    }
    /// The caller retains telemetry and execution effects; this owner gates
    /// failures once shutdown has begun and awaits the same teardown path.
    public func failProtocol(fail: () -> Void, shutdown: () async -> Void,
            isolation: isolated (any Actor)? = #isolation) async {
        guard !isShuttingDown else { return }
        fail()
        await shutdown()
    }

    public enum InterruptObservation {
        case acknowledged(target: ClaudeTurnGeneration?)
        case timedOut
        case failed(any Error)
    }
    public func interrupt(hasProcess: () -> Bool, hasTurn: () -> Bool,
            headGeneration: () -> ClaudeTurnGeneration?, send: () async throws -> Void,
            observe: (InterruptObservation) -> Void, isolation: isolated (any Actor)? = #isolation) async -> ClaudeNativeInterruptOutcome {
        guard hasProcess() else { return .failed }
        guard hasTurn() else { return .noTurnInFlight }
        let intended = headGeneration()
        do { try await send(); observe(.acknowledged(target: intended)); return .acknowledged }
        catch {
            if let error = error as? ClaudeNativeClientError, case .controlRequestTimedOut = error {
                observe(.timedOut); return .timedOut
            }
            observe(.failed(error)); return .failed
        }
    }
}
