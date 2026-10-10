import Foundation
import AIClientKit
import ClaudeRuntimeKit
import AgentClaudeProtocol
import AgentClaudeContent
import AgentClaudeEvents
import AgentClaudeMetadata
import AgentClaudeSession
@_spi(Testing) import AgentClaudeLifecycle

/// Serialized execution owner for one native client. Transport, admission,
/// permission policy and telemetry are explicit host ports. The owner composes
/// initialization, metadata, content, lifecycle and event-stream state without
/// exposing mutable child services or importing a host module.
public final class ClaudeNativeExecution {
	public struct Token: Equatable, Sendable {
		fileprivate let transport: UUID
		fileprivate let stream: ClaudeNativeEventChannel.Token
	}
	/// Single-use lifecycle dispatch authority, including deferred EOF/failure
	/// drains. Transport replacement still invalidates the underlying capability.
	public struct PendingLifecycle: Sendable {
		fileprivate let batch: ClaudeTurnLifecycle.Batch
		public var observation: ClaudeShadowLifecycleRecord { batch.observation }
	}
	public enum Observation: Sendable {
		case payload(ClaudeProtocolJSONObject)
		case systemInit(ClaudeMetadataCodec.SystemInitFields, sessionID: String?)
		case projection(ClaudeProtocolJSONObject, results: [AIStreamResult])
		case streamResult(AIStreamResult, suppressed: Bool)
		case lifecycleEffect(ClaudeTurnLifecycle.Effect)
		case lifecycleSettled
		case transportStarted
		case willEmit(ClaudeNativeEvent)
	}
	public typealias Observer = (Observation) -> Void
	private let eventsOwner = ClaudeNativeEventChannel()
	private let metadata = ClaudeRuntimeMetadata()
	private let lifecycle = ClaudeTurnLifecycle()
	private let content: ClaudeContentPipeline
	private let initialization: ClaudeSessionInitialization
	private let unavailable: @Sendable () -> any Error
	private var transportScope = UUID()
	public init(authority: ClaudeProjectionAuthority, enableDebugLogging: Bool = false,
		translatorPolicy: ClaudeTranslatorPolicy, unavailable: @escaping @Sendable () -> any Error) {
		content = ClaudeContentPipeline(authority: authority, enableDebugLogging: enableDebugLogging, policy: translatorPolicy)
		initialization = ClaudeSessionInitialization(retiredError: unavailable); self.unavailable = unavailable
	}
	public var token: Token { .init(transport: transportScope, stream: eventsOwner.token) }
	public var events: AsyncStream<ClaudeNativeEvent> { eventsOwner.events }
	public var isEventStreamOpen: Bool { eventsOwner.isOpen }
	public var sessionID: String? { metadata.sessionID }
	public var runtimeSnapshot: ClaudeRuntimeInitStatus { metadata.snapshot }
	public var projectionAuthority: ClaudeProjectionAuthority { content.authority }
	public var diagnostics: ClaudeRuntimeDiagnosticAccumulator { content.diagnostics }
	public var isInitialized: Bool { initialization.isInitialized }
	public var hasOpenTurns: Bool { lifecycle.hasOpenTurns }
	public var pendingTurnCount: Int { lifecycle.pendingTurnCount }
	public var headTurnGeneration: ClaudeTurnGeneration? { lifecycle.headTurnGeneration }
	public var hasDeferredOutcomes: Bool { lifecycle.hasDeferredOutcomes }
	public var lifecycleObservations: [ClaudeShadowLifecycleRecord] { lifecycle.observations }
	public var observedInputCount: Int { lifecycle.observedInputCount }
	public var completions: [ClaudeReconciledCompletion] { lifecycle.completions }
	public func generation(for id: UUID) -> ClaudeTurnGeneration? { lifecycle.generation(for: id) }
	public func ensureEventsReady() { eventsOwner.ensureReady() }
	public func resetEventsForNewRun() { eventsOwner.reset() }
	public func finishEvents() { eventsOwner.finish() }
	public func beginLaunch() { transportScope = UUID(); initialization.beginLaunch() }
	public func storeSettings(_ request: ClaudeProtocolJSONObject?) { initialization.storeSettings(request) }
	public func retireInitialization() { transportScope = UUID(); initialization.retire() }
	public func beginTransportEpoch(observe: Observer) {
		transportScope = UUID(); lifecycle.beginNewEpoch()
		let stamp = token
		applyLifecycle(ingestLifecycle(.host(.transportReestablished)), observe: observe)
		guard stamp == token else { return }
		observe(.transportStarted)
		guard stamp == token else { return }
		metadata.resetObservations()
	}
	@discardableResult public func openTurn(id: UUID = UUID()) -> UUID { lifecycle.openTurn(id: id).id }
	public func clearTurns() { lifecycle.clearTurns() }
	public func ingestLifecycle(_ input: ClaudeLifecycleInput, observedOutcome: ClaudeTurnOutcome? = nil) -> PendingLifecycle {
		.init(batch: lifecycle.ingest(input, observedOutcome: observedOutcome))
	}
	public func applyLifecycle(_ pending: PendingLifecycle, observe: Observer) {
		apply(pending, producer: token, observe: observe)
	}
	private func apply(_ pending: PendingLifecycle, producer: Token, observe: Observer) {
		lifecycle.apply(pending.batch) { effect in
			guard producer == token else { return }
			observe(.lifecycleEffect(effect))
			guard producer == token else { return }
			if case .completed(let turn, let outcome, _) = effect {
				emit(.turnCompleted(turnID: turn.id, status: Self.turnStatus(for: outcome)), for: producer, observe: observe)
			}
		}
		if producer == token { observe(.lifecycleSettled) }
	}
	private static func turnStatus(for outcome: ClaudeTurnOutcome) -> ClaudeNativeTurnStatus {
		switch outcome { case .completed: return .completed; case .cancelled: return .cancelled; case .failed: return .failed }
	}
	public func emit(_ event: ClaudeNativeEvent, for producer: Token? = nil, observe: Observer) {
		let stamp = producer ?? token
		guard stamp == token else { return }
		observe(.willEmit(event)); guard stamp == token else { return }
		eventsOwner.emit(event, for: stamp.stream)
	}
	public func recordSessionID(_ candidate: String?, observe: Observer) {
		let stamp = token
		metadata.recordSessionID(candidate) { emit(.runtimeInit($0), for: stamp, observe: observe) }
	}
	public func publishRuntimeInit(observe: Observer) {
		let stamp = token
		metadata.publishIfChanged { emit(.runtimeInit($0), for: stamp, observe: observe) }
	}
	/// The same response is observed, stored and admitted. Readiness is established
	/// only after settings, permission round trip and the host's admission callback.
	public func initialize(request: ClaudeProtocolJSONObject, timeoutSeconds: TimeInterval?, rpc: ClaudeSessionInitialization.RPC,
		onResponse: (ClaudeProtocolJSONObject) throws -> Void,
		onSnapshot: (ClaudeProtocolJSONObject, ClaudeRuntimeInitStatus.InitializeResponseSnapshot) throws -> Void,
		observeSettings: (ClaudeSessionInitialization.Event) -> Void,
		applyPermissionMode: () async throws -> Void, admit: (ClaudeProtocolJSONObject) async throws -> Void,
		observe: Observer, isolation: isolated (any Actor)? = #isolation) async throws {
		let stamp = token
		try await initialization.initialize(request: request, timeoutSeconds: timeoutSeconds, rpc: rpc,
			onResponse: { response in
				guard stamp == token else { throw unavailable() }
				try onResponse(response)
				guard stamp == token else { throw unavailable() }
				guard let snapshot = try metadata.recordInitialize(response, emit: { emit(.runtimeInit($0), for: stamp, observe: observe) }), stamp == token else { throw unavailable() }
				try onSnapshot(response, snapshot)
				guard stamp == token else { throw unavailable() }
			}, observeSettings: { event in if stamp == token { observeSettings(event) } }, applyPermissionMode: {
				guard stamp == token else { throw unavailable() }
				try await applyPermissionMode()
				guard stamp == token else { throw unavailable() }
			},
			admit: { response in
				guard stamp == token else { throw unavailable() }
				try await admit(response)
				guard stamp == token else { throw unavailable() }
			}, onReady: { publishRuntimeInit(observe: observe) }, isolation: isolation)
	}
	public func applyLiveSettings(resolve: () async throws -> ClaudeProtocolJSONObject?, isProcessAvailable: () -> Bool,
		rpc: ClaudeSessionInitialization.RPC, observeSettings: (ClaudeSessionInitialization.Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws -> ClaudeSessionInitialization.ApplyOutcome {
		try await initialization.applyLiveSettings(resolve: resolve, isProcessAvailable: isProcessAvailable, rpc: rpc, observe: observeSettings, isolation: isolation)
	}
	public func consume(_ object: ClaudeProtocolJSONObject, for producer: Token? = nil, observe: Observer) throws {
		let stamp = producer ?? token; guard stamp == token else { return }
		let payload = try object.dictionary()
		let pending: PendingLifecycle?
		if let event = ClaudeLifecycleIngressExtractor.lifecycleEvent(from: payload) {
			let outcome = event.phase == .resultObserved ? Self.outcome(try ClaudeNativeTurnStatusClassifier.classify(object)) : nil
			pending = ingestLifecycle(.wire(event), observedOutcome: outcome)
		} else { pending = nil }
		defer { if let pending { apply(pending, producer: stamp, observe: observe) } }
		recordSessionID(try ClaudeMetadataCodec.firstSessionIdentifier(object), observe: observe)
		guard stamp == token else { return }
		observe(.payload(object)); guard stamp == token else { return }
		_ = try metadata.recordSystemInit(object, observe: { fields in observe(.systemInit(fields, sessionID: sessionID)) }, emit: { emit(.runtimeInit($0), for: stamp, observe: observe) })
		guard stamp == token else { return }
		let frame = content.translate(object.data)
		observe(.projection(object, results: frame.results)); guard stamp == token else { return }
		for step in frame.steps {
			guard stamp == token else { return }
			switch step {
			case .sessionID(let id): recordSessionID(id, observe: observe)
			case .observeResult(let result, let suppressed): observe(.streamResult(result, suppressed: suppressed))
			case .emit(let event): emit(event, for: stamp, observe: observe)
			}
		}
	}
	private static func outcome(_ status: ClaudeNativeTurnStatus) -> ClaudeTurnOutcome {
		switch status { case .completed: return .completed; case .cancelled: return .cancelled; case .failed: return .failed }
	}
	/// Corruption fixture only; production cannot separate ledger and reconciliation.
	@_spi(Testing) public func dropLedgerRecordForTesting(id: UUID) { lifecycle.dropLedgerRecordForTesting(id: id) }
}
