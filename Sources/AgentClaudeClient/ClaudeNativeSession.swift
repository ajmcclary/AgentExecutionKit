import Foundation
import AgentRuntimeKit
import ClaudeRuntimeKit
import AgentClaudeProtocol
import AgentClaudeControl
import AgentClaudePermissions
import AgentClaudeCapabilities
import AgentClaudeSession
import AgentClaudeEvents
import AgentClaudeContent
@_spi(Testing) import AgentClaudeExecution
import AgentNativeProcessTransport

/// One caller-actor-owned native session. Execution, control/permission scope and
/// client resources are private. Hosts supply connection I/O, admission, settings,
/// authorization and observations; no app, preferences or credential lookup occurs.
public final class ClaudeNativeSession {
    private let execution: ClaudeNativeExecution
    private let protocolSession: ClaudeNativeProtocolSession
    private let clientLifecycle = ClaudeNativeClientLifecycle()
    private let unavailable: @Sendable () -> any Error
    public init(requestIDPrefix: String, authority: ClaudeProjectionAuthority,
                enableDebugLogging: Bool = false, translatorPolicy: ClaudeTranslatorPolicy,
                unavailable: @escaping @Sendable () -> any Error = { ClaudeNativeClientError.processNotRunning },
                controlSleep: @escaping ClaudeControlChannel.Sleep = { try await Task.sleep(for: $0) },
                idleSleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                }) {
        self.unavailable = unavailable
        execution = .init(authority: authority, enableDebugLogging: enableDebugLogging,
                          translatorPolicy: translatorPolicy, unavailable: unavailable, sleep: idleSleep)
        protocolSession = .init(requestIDPrefix: requestIDPrefix, sleep: controlSleep)
    }
    public var events: AsyncStream<ClaudeNativeEvent> { execution.events }
    public var sessionID: String? { execution.sessionID }
    public var isInitialized: Bool { execution.isInitialized }
    public var isEventStreamOpen: Bool { execution.isEventStreamOpen }
    public var hasOpenTurns: Bool { execution.hasOpenTurns }
    public var hasDeferredOutcomes: Bool { execution.hasDeferredOutcomes }
    public var pendingTurnCount: Int { execution.pendingTurnCount }
    public var headTurnGeneration: ClaudeTurnGeneration? { execution.headTurnGeneration }
    public var runtimeSnapshot: ClaudeRuntimeInitStatus { execution.runtimeSnapshot }
    public var projectionAuthority: ClaudeProjectionAuthority { execution.projectionAuthority }
    public var lifecycleObservations: [ClaudeShadowLifecycleRecord] { execution.lifecycleObservations }
    public var observedInputCount: Int { execution.observedInputCount }
    public var completions: [ClaudeReconciledCompletion] { execution.completions }
    public var configURL: URL? { clientLifecycle.configURL }
    public var isShuttingDown: Bool { clientLifecycle.isShuttingDown }
    public var pendingControlRequestIDs: [String] { protocolSession.pendingControlRequestIDs }
    public var pendingPermissionRequestIDs: [String] { protocolSession.pendingPermissionRequestIDs }
    public func generation(for id: UUID) -> ClaudeTurnGeneration? { execution.generation(for: id) }
    public func ensureEventsReady() { execution.ensureEventsReady() }
    public func resetEventsForNewRun() { execution.resetEventsForNewRun() }
    public func consume(_ payload: ClaudeProtocolJSONObject, observe: ClaudeNativeExecution.Observer) throws {
        try execution.consume(payload, observe: observe)
    }
    public func emit(_ event: ClaudeNativeEvent, observe: ClaudeNativeExecution.Observer) { execution.emit(event, observe: observe) }
    public func ingestLifecycle(_ input: ClaudeLifecycleInput, observedOutcome: ClaudeTurnOutcome? = nil) -> ClaudeNativeExecution.PendingLifecycle {
        execution.ingestLifecycle(input, observedOutcome: observedOutcome)
    }
    public func applyLifecycle(_ pending: ClaudeNativeExecution.PendingLifecycle, observe: ClaudeNativeExecution.Observer) {
        execution.applyLifecycle(pending, observe: observe)
    }
    public func reconcileIdleFallback(seconds: TimeInterval, deliver: @escaping @Sendable (ClaudeNativeExecution.IdleFallbackToken) async -> Void) {
        execution.reconcileIdleFallback(seconds: seconds, deliver: deliver)
    }
    public func fireIdleFallback(_ token: ClaudeNativeExecution.IdleFallbackToken, observeFallback: () -> Void, observe: ClaudeNativeExecution.Observer) {
        execution.fireIdleFallback(token, observeFallback: observeFallback, observe: observe)
    }
    public func cancelIdleFallback() { execution.cancelIdleFallback() }

    public func startOrResume(hasProcess: @escaping () -> Bool, observeStart: @escaping () -> Void,
                             prepare: @escaping () async throws -> Void, spawn: @escaping () async throws -> Void,
                             initialize: @escaping () async throws -> Void, shutdown: @escaping () async -> Void,
                             isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeNativeSessionRef {
        try await clientLifecycle.startOrResume(actions: .init(isReady: { hasProcess() && self.execution.isInitialized },
            reference: { ClaudeNativeSessionRef(sessionID: self.execution.sessionID) },
            ensureEvents: { self.execution.ensureEventsReady() }, observeStart: observeStart,
            prepare: prepare, spawn: spawn, initialize: initialize, hasProcess: hasProcess, shutdown: shutdown), isolation: isolation)
    }
    public func prepareRuntime(preparer: ClaudeNativeRuntimePreparer, unavailable: @Sendable () -> any Error,
                               isolation: isolated (any Actor)? = #isolation) async throws {
        try await clientLifecycle.prepareRuntime(preparer: preparer, unavailable: unavailable, isolation: isolation)
    }
    public func tearDownTransport(invalidate: () -> AgentNativeProcessTransport.TerminationLease?,
                                  clearRegistration: @escaping @Sendable () async -> Void,
                                  isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.tearDownTransport(invalidate: invalidate, clearRegistration: clearRegistration, isolation: isolation)
    }
    public func registerPID(_ pid: Int32, clientName: String?, runID: UUID, registrar: ClaudeExpectedAgentPIDRegistrar,
                            generation: () -> UInt64, registered: () -> Void,
                            isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.registerPID(pid, clientName: clientName, runID: runID, registrar: registrar,
                                          generation: generation, registered: registered, isolation: isolation)
    }
    public func clearPID(clientName: String?, runID: UUID, registrar: ClaudeExpectedAgentPIDRegistrar, cleared: () -> Void,
                         isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.clearPID(clientName: clientName, runID: runID, registrar: registrar, cleared: cleared, isolation: isolation)
    }
    /// The exact admitted launch supplies both spawn input and stored settings.
    /// Admission state and concrete connection I/O remain independent owners.
    public func startTransport<Context: Sendable, Effort: RawRepresentable & Equatable & Sendable, Source: Equatable & Sendable>(
        hasProcess: () -> Bool, resetAdmission: () -> Void,
        admit: () async throws -> ClaudeAdmittedLaunch<Context, Effort, Source>,
        adopt: (ClaudeAdmittedLaunch<Context, Effort, Source>) -> Void,
        spawn: (ClaudeAdmittedLaunch<Context, Effort, Source>) throws -> Int32,
        startReaders: () throws -> Void, invalidateReaders: () async -> Void,
        registerPID: (Int32) async -> Void, observe: ClaudeNativeExecution.Observer,
        isolation: isolated (any Actor)? = #isolation
    ) async throws where Effort.RawValue == String {
        try await clientLifecycle.startTransport(hasProcess: hasProcess, resetEpoch: {
            resetAdmission(); execution.beginLaunch()
        }, admit: admit, adopt: { launch in
            adopt(launch); execution.storeSettings(launch.plan.flagSettingsRequest)
        }, spawn: spawn, beginEpoch: {
            protocolSession.beginScope(); execution.beginTransportEpoch(observe: observe)
        }, startReaders: startReaders, invalidateReaders: invalidateReaders, registerPID: registerPID, isolation: isolation)
    }
    /// Initialization owns the permission observation carried to final admission.
    /// Host counters, elapsed-time policy and diagnostics stay in callbacks.
    public func initialize(systemPromptOverride: String?, timeoutSeconds: TimeInterval?, rpc: ClaudeSessionInitialization.RPC,
                           onResponse: (ClaudeProtocolJSONObject) throws -> Void,
                           onSnapshot: (ClaudeProtocolJSONObject, ClaudeRuntimeInitStatus.InitializeResponseSnapshot) throws -> Void,
                           observeSettings: (ClaudeSessionInitialization.Event) -> Void,
                           permissionModeRequest: () throws -> ClaudeProtocolJSONObject?,
                           observePermissionMode: (ClaudeNativePermissionMode.Observation) -> Void,
                           admit: (ClaudeProtocolJSONObject, ClaudePermissionModeRoundTrip) async throws -> Void,
                           observe: ClaudeNativeExecution.Observer,
                           isolation: isolated (any Actor)? = #isolation) async throws {
        guard !execution.isInitialized else { return }
        var permissionModeRoundTrip: ClaudePermissionModeRoundTrip = .notAttempted
        try await execution.initialize(request: ClaudeNativeSessionContract.initializeRequest(systemPromptOverride: systemPromptOverride),
            timeoutSeconds: timeoutSeconds, rpc: rpc, onResponse: onResponse, onSnapshot: onSnapshot,
            observeSettings: observeSettings, applyPermissionMode: {
                permissionModeRoundTrip = try await ClaudeNativePermissionMode.apply(request: permissionModeRequest(),
                    rpc: { try await rpc($0, nil) }, observe: observePermissionMode, isolation: isolation)
            }, admit: { response in try await admit(response, permissionModeRoundTrip) }, observe: observe, isolation: isolation)
    }
    public func applyLiveSettings(isProcessAvailable: () -> Bool, admit: () throws -> Void,
                                  resolve: () async throws -> ClaudeProtocolJSONObject?, rpc: ClaudeSessionInitialization.RPC,
                                  observeSettings: (ClaudeSessionInitialization.Event) -> Void,
                                  isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeSessionInitialization.ApplyOutcome {
        guard isProcessAvailable() else { return .noProcess }
        try admit()
        return try await execution.applyLiveSettings(resolve: resolve, isProcessAvailable: isProcessAvailable,
                                                     rpc: rpc, observeSettings: observeSettings, isolation: isolation)
    }
    @discardableResult public func sendUserMessage(_ text: String, isAvailable: () -> Bool, write: (Data) throws -> Void) throws -> UUID {
        try protocolSession.sendUserMessage(text, sessionID: execution.sessionID, isAvailable: isAvailable,
                                            write: write, openTurn: { execution.openTurn() })
    }
    public func interrupt(hasProcess: () -> Bool, send: () async throws -> Void,
                          beforeAcknowledged: () -> Void = {}, observe: (ClaudeNativeClientLifecycle.InterruptObservation) -> Void,
                          isolation: isolated (any Actor)? = #isolation) async -> ClaudeNativeInterruptOutcome {
        await clientLifecycle.interrupt(hasProcess: hasProcess, hasTurn: { execution.hasOpenTurns },
            headGeneration: { execution.headTurnGeneration }, send: send, observe: { value in
                if case .acknowledged(let intended) = value {
                    beforeAcknowledged()
                    if let intended { _ = execution.ingestLifecycle(.host(.interruptRequested(target: intended))) }
                }
                observe(value)
            }, isolation: isolation)
    }
    public func request(_ request: ClaudeProtocolJSONObject, timeoutSeconds: TimeInterval?,
                        onExpiry: @escaping @Sendable (ClaudeNativeProtocolSession.ControlTicket) async -> Void,
                        isAvailable: () -> Bool, observe: (ClaudeNativeProtocolSession.ControlTicket, Bool) -> Void,
                        write: (Data) throws -> Void, isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeProtocolJSONObject {
        try await protocolSession.request(request, timeoutSeconds: timeoutSeconds, onExpiry: onExpiry,
                                           isAvailable: isAvailable, observe: observe, write: write, isolation: isolation)
    }
    public func notify(_ request: ClaudeProtocolJSONObject, isAvailable: () -> Bool,
                       observe: (ClaudeNativeProtocolSession.ControlTicket, Bool) -> Void, write: (Data) throws -> Void) throws {
        try protocolSession.notify(request, isAvailable: isAvailable, observe: observe, write: write)
    }
    public func expire(_ ticket: ClaudeNativeProtocolSession.ControlTicket) { protocolSession.expire(ticket) }
    public func route<Context>(_ inbound: ClaudeNativeProtocolCodec.InboundMessage, routing: ClaudeNativeProtocolSession.Routing<Context>) {
        protocolSession.route(inbound, routing: routing)
    }
    public func respondPermission(id: String, decision: AgentApprovalDecision, write: (Data) throws -> Void,
                                  observe: (ClaudePermissionEngine.Event) -> Void, failure: (any Error) async -> Void,
                                  isolation: isolated (any Actor)? = #isolation) async {
        await protocolSession.respondPermission(id: id, decision: decision, write: write, observe: observe, failure: failure, isolation: isolation)
    }
    /// Failure reaches the event stream before completion; shutdown stays awaited.
    public func failProtocol(message: String, observeFailure: () -> Void, observe: ClaudeNativeExecution.Observer,
                             shutdown: () async -> Void, isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.failProtocol(fail: {
            execution.failProtocol(message: message, observeFailure: observeFailure, observe: observe)
        }, shutdown: shutdown, isolation: isolation)
    }
    public func shutdown(preparer: ClaudeNativeRuntimePreparer, observeShutdown: @escaping () -> Void,
                         teardownTransport: @escaping () async -> Void, retireAdmission: @escaping () -> Void,
                         finish: @escaping () -> Void, observe: @escaping ClaudeNativeExecution.Observer,
                         isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.shutdown(actions: .init(prepare: { [self] in
            observeShutdown()
            protocolSession.failAll(with: unavailable()); protocolSession.retirePermissions()
            execution.applyLifecycle(execution.ingestLifecycle(.host(.shutdownRequested)), observe: observe)
            execution.clearTurns(); execution.cancelIdleFallback()
        }, teardownTransport: teardownTransport, retireEpoch: { [self] in
            execution.retireInitialization(); retireAdmission()
        }, finish: { [self] in
            finish(); execution.finishEvents()
        }), preparer: preparer, isolation: isolation)
    }
    public func handleEOF(generation: UInt64, currentGeneration: () -> UInt64, hasProcess: () -> Bool,
                          observeEOF: () -> Void, flush: () -> String?, failProtocol: (String) async -> Void,
                          teardownTransport: () async -> Void, unexpectedExitMessage: String,
                          observe: ClaudeNativeExecution.Observer,
                          isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.handleEOF(generation: generation, currentGeneration: currentGeneration, hasProcess: hasProcess,
            observeEOF: observeEOF, flush: flush, failProtocol: failProtocol, prepareClose: {
                protocolSession.failAll(with: unavailable()); protocolSession.retirePermissions()
                let hadOpenTurns = execution.hasOpenTurns
                let pending = execution.ingestLifecycle(.host(.transportClosed))
                execution.cancelIdleFallback()
                return (hadOpenTurns, pending)
            }, teardownTransport: teardownTransport, finishClose: { close in
                execution.retireInitialization()
                if close.0 { execution.emit(.error(unexpectedExitMessage), observe: observe) }
                execution.applyLifecycle(close.1, observe: observe)
                execution.clearTurns(); execution.finishEvents()
            }, isolation: isolation)
    }
    public func writeLine(_ data: Data, shutdownOnFailure: Bool, hasProcess: () -> Bool, generation: () -> UInt64,
                          write: (Data) throws -> Void, scheduleShutdown: (UInt64) -> Void) throws {
        try clientLifecycle.writeLine(data, shutdownOnFailure: shutdownOnFailure, hasProcess: hasProcess,
                                      generation: generation, write: write, scheduleShutdown: scheduleShutdown)
    }
    public func shutdownAfterWriteFailure(generation: UInt64, currentGeneration: () -> UInt64, hasProcess: () -> Bool,
                                         shutdown: () async -> Void, isolation: isolated (any Actor)? = #isolation) async {
        await clientLifecycle.shutdownAfterWriteFailure(generation: generation, currentGeneration: currentGeneration,
                                                        hasProcess: hasProcess, shutdown: shutdown, isolation: isolation)
    }
    @_spi(Testing) public func beginStart() { clientLifecycle.beginStart() }
    @_spi(Testing) public func setConfigURLForTesting(_ url: URL?) { clientLifecycle.setConfigURLForTesting(url) }
    @_spi(Testing) @discardableResult public func openTurn(id: UUID = UUID()) -> UUID { execution.openTurn(id: id) }
    @_spi(Testing) public func dropLedgerRecordForTesting(id: UUID) { execution.dropLedgerRecordForTesting(id: id) }
    @_spi(Testing) public func receiveRequest<Context>(_ request: ClaudeNativeProtocolCodec.ControlRequest, routing: ClaudeNativeProtocolSession.Routing<Context>) {
        protocolSession.receiveRequest(request, routing: routing)
    }
}
