import Foundation
import Darwin
import Darwin.POSIX.fcntl
import AgentRuntimeKit
import CodexRuntimeKit
import CodexAppServerKit
import ProcessKit

// Client execution extracted from RepoPrompt. Host policy arrives through HostServices.

public actor CodexAgentClient {
	// Protocol vocabulary lives in CodexRuntimeKit (promoted 2026-07-17).
	// These aliases keep the existing `CodexAppServerClient.X` consumers
	// compiling; new code should use the Codex-prefixed core names directly.
	public typealias RemoteReasoningEffort = CodexRemoteReasoningEffort
	public typealias RemoteModel = CodexRemoteModel
	public typealias ServerRequest = CodexServerRequest
	public typealias Notification = CodexServerNotification
	public typealias ClientError = CodexClientError
	public typealias TransportTerminationReason = CodexTransportTerminationReason

	public struct Config: Sendable, Equatable {
		public let commandName: String
		public let additionalPathHints: [String]
		public let enableDebugLogging: Bool
		public let requestTimeout: TimeInterval?
		/// Working directory for the Codex app-server process.
		/// When nil, falls back to temp directory via the process transport default.
		public let workingDirectory: String?
		public let processFeaturePolicy: CodexProcessFeaturePolicy
		/// Extra environment variables applied to the spawned app-server process
		/// (e.g. `OPENAI_API_KEY` for in-app Codex API-key auth). Non-destructive:
		/// per-process, never written to `~/.codex`.
		public let environmentOverrides: [String: String]
		/// Retry policy for overloaded (`-32001`) requests.
		public let backoffPolicy: CodexBackoffPolicy
		/// Named experimental requirements for the NEXT transport start.
		/// Empty means stable-only initialization (no `experimentalApi` key at
		/// all). Frozen into an immutable per-transport admission at spawn;
		/// change via `updateExperimentalRequirements`, which restarts a
		/// running transport so admission always matches policy.
		public let experimentalRequirements: Set<CodexExperimentalRequirement>

		public init(
			commandName: String,
			additionalPathHints: [String],
			enableDebugLogging: Bool = false,
			requestTimeout: TimeInterval? = nil,
			workingDirectory: String? = nil,
			processFeaturePolicy: CodexProcessFeaturePolicy = .defaultDisabled,
			environmentOverrides: [String: String] = [:],
			backoffPolicy: CodexBackoffPolicy = .default,
			experimentalRequirements: Set<CodexExperimentalRequirement> = []
		) {
			self.commandName = commandName
			self.additionalPathHints = additionalPathHints
			self.enableDebugLogging = enableDebugLogging
			self.requestTimeout = requestTimeout
			self.workingDirectory = workingDirectory
			self.processFeaturePolicy = processFeaturePolicy
			self.environmentOverrides = environmentOverrides
			self.backoffPolicy = backoffPolicy
			self.experimentalRequirements = experimentalRequirements
		}

		/// Copies the config with only `workingDirectory` replaced. Targeted
		/// updates must go through these helpers rather than the memberwise
		/// initializer so newly added fields can never be silently dropped.
		public func replacingWorkingDirectory(_ workingDirectory: String?) -> Config {
			Config(
				commandName: commandName,
				additionalPathHints: additionalPathHints,
				enableDebugLogging: enableDebugLogging,
				requestTimeout: requestTimeout,
				workingDirectory: workingDirectory,
				processFeaturePolicy: processFeaturePolicy,
				environmentOverrides: environmentOverrides,
				backoffPolicy: backoffPolicy,
				experimentalRequirements: experimentalRequirements
			)
		}

		/// Copies the config with only `processFeaturePolicy` replaced.
		public func replacingProcessFeaturePolicy(_ featurePolicy: CodexProcessFeaturePolicy) -> Config {
			Config(
				commandName: commandName,
				additionalPathHints: additionalPathHints,
				enableDebugLogging: enableDebugLogging,
				requestTimeout: requestTimeout,
				workingDirectory: workingDirectory,
				processFeaturePolicy: featurePolicy,
				environmentOverrides: environmentOverrides,
				backoffPolicy: backoffPolicy,
				experimentalRequirements: experimentalRequirements
			)
		}

		/// Copies the config with only `experimentalRequirements` replaced.
		public func replacingExperimentalRequirements(_ requirements: Set<CodexExperimentalRequirement>) -> Config {
			Config(
				commandName: commandName,
				additionalPathHints: additionalPathHints,
				enableDebugLogging: enableDebugLogging,
				requestTimeout: requestTimeout,
				workingDirectory: workingDirectory,
				processFeaturePolicy: processFeaturePolicy,
				environmentOverrides: environmentOverrides,
				backoffPolicy: backoffPolicy,
				experimentalRequirements: requirements
			)
		}
	}

	/// JSON-RPC error code Codex app-server returns when overloaded; retried with backoff.
	public static let overloadErrorCode = CodexBackoffPolicy.overloadErrorCode

	public struct ExpectedAgentPIDRegistration: Sendable, Equatable {
		public let clientName: String
		public let runID: UUID
		public init(clientName: String, runID: UUID) {
			self.clientName = clientName
			self.runID = runID
		}
	}

	public struct ExpectedAgentPIDRegistrar: Sendable {
		public let register: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
		public let clear: @Sendable (_ pid: pid_t, _ clientName: String, _ runID: UUID) async -> Void
		public init(
			register: @escaping @Sendable (pid_t, String, UUID) async -> Void,
			clear: @escaping @Sendable (pid_t, String, UUID) async -> Void
		) {
			self.register = register
			self.clear = clear
		}
	}

	private struct RegisteredExpectedAgentPID: Sendable, Equatable {
		let pid: pid_t
		let clientName: String
		let runID: UUID
	}

	private struct TerminatingTransport {
		let snapshot: CodexAppServerProcessTransport.TerminationSnapshot
		let expectedAgentPIDToClear: RegisteredExpectedAgentPID?
	}

	public static func isTimeoutError(_ error: Error) -> Bool {
		CodexRequestTimeoutPolicy.isTimeoutError(error)
	}

	public private(set) var config: Config
	private let host: HostServices
	/// Sole owner of the child process, pipe channels, reader tasks, stdin
	/// writes, liveness, the transport generation, and the termination
	/// snapshot. Synchronous component confined to this actor.
	private let transport: CodexAppServerProcessTransport
	/// Sole owner of request IDs, pending continuations, metadata, and timeout
	/// tasks; synchronous, executes under this actor.
	private let requestStore = CodexRPCRequestStore()
	private var notificationContinuations: [UUID: AsyncStream<Notification>.Continuation] = [:]
	private var serverRequestContinuations: [UUID: AsyncStream<ServerRequest>.Continuation] = [:]
	private var isInitialized = false
	/// Sole owner of stdout framing, decoding, recovery heuristics, and the
	/// per-transport recovery budget; replaced on every process (re)start.
	private var stdoutDecoder = CodexJSONStreamDecoder()
	private var lastTransportTerminationReason: TransportTerminationReason?
	/// Immutable experimental admission for the CURRENT transport, frozen
	/// from `config.experimentalRequirements` at spawn — BEFORE initialize —
	/// and cleared on invalidation. Requests are gated against this value,
	/// never against live config, so admission can never drift mid-transport.
	private var experimentalAdmission: CodexExperimentalAdmission?
	/// Diagnostics reason attached to the next admission freeze.
	private var experimentalRequirementsReason = CodexExperimentalAdmission.stableOnly.reason
	/// Per-generation admission history for diagnostics (bounded).
	private var experimentalAdmissionHistory: [CodexExperimentalAdmissionRecord] = []
	private static let maxAdmissionHistoryCount = 16
	private var startupTask: (id: UUID, task: Task<Void, Error>)?
	private var expectedAgentPIDRegistration: ExpectedAgentPIDRegistration?
	private var registeredExpectedAgentPID: RegisteredExpectedAgentPID?
	private let expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar

	public init(
		configuration: Config,
		host: HostServices,
		writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { descriptor, frame in
			try FDWriteSupport.writeAll(frame, to: descriptor)
		},
		livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { process in
			CodexAppServerProcessTransport.defaultProcessAppearsAlive(process)
		},
		expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar,
		readPreflight: @escaping @Sendable (Int32, String) throws -> Void
	) {
		self.config = configuration
		self.host = host
		self.transport = CodexAppServerProcessTransport(
			writeFrameHandler: writeFrameHandler,
			livenessProbe: livenessProbe,
			readPreflight: readPreflight
		)
		self.expectedAgentPIDRegistrar = expectedAgentPIDRegistrar
	}

	public func updateConfig(_ config: Config) {
		self.config = config
	}

	public func setExpectedAgentPIDRegistration(_ registration: ExpectedAgentPIDRegistration?) async {
		expectedAgentPIDRegistration = registration
		guard registration != nil else {
			await clearRegisteredExpectedAgentPIDIfNeeded()
			return
		}
		guard let pid = transport.pid else {
			await clearRegisteredExpectedAgentPIDIfNeeded()
			return
		}
		await registerExpectedAgentPIDIfNeeded(for: pid)
	}

	public func clearExpectedAgentPIDRegistration() async {
		expectedAgentPIDRegistration = nil
		await clearRegisteredExpectedAgentPIDIfNeeded()
	}

	private func registerExpectedAgentPIDIfNeeded(for pid: pid_t) async {
		guard let registration = expectedAgentPIDRegistration else { return }
		let target = RegisteredExpectedAgentPID(
			pid: pid,
			clientName: registration.clientName,
			runID: registration.runID
		)
		guard registeredExpectedAgentPID != target else { return }
		await clearRegisteredExpectedAgentPIDIfNeeded()
		guard expectedAgentPIDRegistration == registration, transport.pid == pid else { return }
		registeredExpectedAgentPID = target
		await expectedAgentPIDRegistrar.register(target.pid, target.clientName, target.runID)
		guard expectedAgentPIDRegistration == registration, transport.pid == pid else {
			if registeredExpectedAgentPID == target {
				registeredExpectedAgentPID = nil
			}
			await expectedAgentPIDRegistrar.clear(target.pid, target.clientName, target.runID)
			return
		}
	}

	private func clearRegisteredExpectedAgentPIDIfNeeded() async {
		guard let registered = takeRegisteredExpectedAgentPIDForDeferredClear() else { return }
		await expectedAgentPIDRegistrar.clear(registered.pid, registered.clientName, registered.runID)
	}

	private func takeRegisteredExpectedAgentPIDForDeferredClear() -> RegisteredExpectedAgentPID? {
		let registered = registeredExpectedAgentPID
		registeredExpectedAgentPID = nil
		return registered
	}

	/// Updates the working directory for the next process start.
	/// Must be called before `startIfNeeded()` to take effect.
	public func updateWorkingDirectory(_ path: String?) {
		let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
		config = config.replacingWorkingDirectory(normalized)
	}

	public func updateProcessFeaturePolicy(_ featurePolicy: CodexProcessFeaturePolicy) async {
		guard featurePolicy != config.processFeaturePolicy else { return }
		config = config.replacingProcessFeaturePolicy(featurePolicy)
		if transport.hasProcess {
			await terminateTransport(flushStdout: true, reason: .explicitStop)
		}
	}

	/// Sets the named experimental requirements for the next transport.
	/// Because admission is immutable per transport, any change while a
	/// process is running restarts the transport — enabling the first
	/// requirement upgrades the next generation to experimental, and
	/// disabling the last one returns it to stable-only.
	public func updateExperimentalRequirements(
		_ requirements: Set<CodexExperimentalRequirement>,
		reason: String
	) async {
		experimentalRequirementsReason = requirements.isEmpty
			? CodexExperimentalAdmission.stableOnly.reason
			: reason
		guard requirements != config.experimentalRequirements else { return }
		config = config.replacingExperimentalRequirements(requirements)
		if transport.hasProcess {
			await terminateTransport(flushStdout: true, reason: .explicitStop)
		}
	}

	/// Admission history per transport generation, for diagnostics.
	public func experimentalAdmissionRecords() -> [CodexExperimentalAdmissionRecord] {
		experimentalAdmissionHistory
	}

	public func currentExperimentalAdmission() -> CodexExperimentalAdmission? {
		experimentalAdmission
	}

	public func subscribeNotifications() -> AsyncStream<Notification> {
		AsyncStream { continuation in
			let id = UUID()
			notificationContinuations[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removeNotificationContinuation(id) }
			}
		}
	}

	public func subscribeServerRequests() -> AsyncStream<ServerRequest> {
		AsyncStream { continuation in
			let id = UUID()
			serverRequestContinuations[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removeServerRequestContinuation(id) }
			}
		}
	}

	public func startIfNeeded() async throws {
		if let existingStartupTask = startupTask?.task {
			return try await existingStartupTask.value
		}
		if transport.hasProcess {
			let appearsAlive = transport.processAppearsAlive
			if isInitialized, appearsAlive {
				return
			}
			if !appearsAlive {
				scheduleTransportCleanup(
					invalidateTransport(
						flushStdout: false,
						requestFailure: .processNotRunning,
						reason: .livenessCheckFailed(method: nil)
					)
				)
			}
		}
		let startupID = UUID()
		let task = Task<Void, Error> {
			try await self.performStartupIfNeeded()
		}
		startupTask = (id: startupID, task: task)
		do {
			try await task.value
			if startupTask?.id == startupID {
				startupTask = nil
			}
		} catch {
			if startupTask?.id == startupID {
				startupTask = nil
			}
			throw error
		}
	}

	public func stop() async {
		startupTask?.task.cancel()
		startupTask = nil
		await terminateTransport(flushStdout: true, reason: .explicitStop)
	}

	// MARK: - Authoritative transport termination

	/// Single, idempotent teardown path for the process transport layer.
	///
	/// Called from `handleStdoutEOF()` (EOF detected on stdout) and `stop()` (explicit shutdown).
	/// Responsible for: flushing remaining stdout, cancelling consumer tasks, failing all
	/// pending requests, finishing all notification/serverRequest subscriber continuations,
	/// and cleaning up the process. Idempotent via `didTerminateTransport` flag.
	///
	/// Note: `flushStdout` is best-effort; buffered channel bytes that have not yet been
	/// fed into `stdoutDecoder` may still be dropped during teardown.
	///
	/// When `expectedGeneration` is provided, the call is a no-op if the current
	/// `transportGeneration` doesn't match — this prevents a stale consumer task
	/// from tearing down a newly-started transport.
	///
	/// Related:
	/// - ClaudeNativeProcessSessionController.handleStdoutEOF / shutdown (reference implementation)
	/// - FileHandleChunkChannel (FIFO chunk ordering)
	/// - CodexNativeSessionController.startNotificationStreamIfNeeded (downstream subscriber)
	private func terminateTransport(
		flushStdout: Bool,
		expectedGeneration: UInt64? = nil,
		requestFailure: ClientError = .processNotRunning,
		reason: TransportTerminationReason
	) async {
		await finishTransportTermination(
			invalidateTransport(
				flushStdout: flushStdout,
				expectedGeneration: expectedGeneration,
				requestFailure: requestFailure,
				reason: reason
			)
		)
	}

	private func invalidateTransport(
		flushStdout: Bool,
		expectedGeneration: UInt64? = nil,
		requestFailure: ClientError,
		reason: TransportTerminationReason
	) -> TerminatingTransport? {
		// 1. Transport-owned teardown: generation guard, idempotence, chunk
		// channels, consumer tasks, and the process snapshot. Snapshotting +
		// nil-ing the process BEFORE any await prevents actor re-entrancy
		// issues: other calls (startIfNeeded, request, subscribe*) that
		// interleave during ProcessTermination.terminateAndReap will see no
		// process and correctly fail/bail out.
		guard let snapshot = transport.invalidate(expectedGeneration: expectedGeneration) else {
			return nil
		}
		lastTransportTerminationReason = reason

		// 2. Flush remaining stdout lines before failing pending requests
		// (a flushed response may still resolve its request).
		if flushStdout {
			handleDecoderEvents(stdoutDecoder.flush())
		}

		// 3. Cancel all timeout tasks and fail all pending requests.
		requestStore.failAll(error: requestFailure)

		// 4. Finish all notification and serverRequest subscriber streams.
		let notifContinuations = notificationContinuations
		notificationContinuations.removeAll()
		for continuation in notifContinuations.values {
			continuation.finish()
		}

		let serverReqContinuations = serverRequestContinuations
		serverRequestContinuations.removeAll()
		for continuation in serverReqContinuations.values {
			continuation.finish()
		}

		let expectedAgentPIDToClear = takeRegisteredExpectedAgentPIDForDeferredClear()
		isInitialized = false
		experimentalAdmission = nil

		// 5. Reset decoder state for potential future restart.
		stdoutDecoder = CodexJSONStreamDecoder()

		return TerminatingTransport(
			snapshot: snapshot,
			expectedAgentPIDToClear: expectedAgentPIDToClear
		)
	}

	private func scheduleTransportCleanup(_ terminatingTransport: TerminatingTransport?) {
		guard let terminatingTransport else { return }
		Task {
			await self.finishTransportTermination(terminatingTransport)
		}
	}

	private func finishTransportTermination(_ terminatingTransport: TerminatingTransport?) async {
		guard let terminatingTransport else { return }
		if let expectedAgentPIDToClear = terminatingTransport.expectedAgentPIDToClear {
			await expectedAgentPIDRegistrar.clear(
				expectedAgentPIDToClear.pid,
				expectedAgentPIDToClear.clientName,
				expectedAgentPIDToClear.runID
			)
		}
		// Single reap site; the host's termination policy is applied here, at
		// the call, so the package transport carries no RepoPrompt policy.
		//
		// UNSAFE ESCAPE — `finishTermination` is `@concurrent`, so the snapshot
		// leaves this actor's isolation, and `TerminationSnapshot` (it wraps a
		// `SpawnedProcess`) is not `Sendable`. `terminatingTransport` arrives as
		// an ordinary actor-isolated parameter, so no disconnection proof exists
		// even though the value IS exclusively owned here. The package cannot
		// carry the proof for us: `invalidate()` is declared `-> TerminationSnapshot?`
		// rather than `-> sending`, and packages are out of scope for this change.
		//
		// INVARIANT — the snapshot is a one-shot ownership transfer, and this is
		// the hand-off point:
		// - `CodexAppServerProcessTransport.invalidate()` is the ONLY producer of
		//   a `TerminationSnapshot` (its `init` is `fileprivate`). It nils the
		//   transport's `process` before returning, so the snapshot holds the
		//   last reference to the child; it is also idempotent (`isTerminated`)
		//   and generation-guarded, so it can never mint a second snapshot for
		//   the same process.
		// - `finishTermination` is `static` and state-free by design — the
		//   package's own comment says the snapshot "can be finished from any
		//   task without touching the actor-confined transport". It reads only
		//   `snapshot.process`.
		// - This actor never stores a `TerminatingTransport`: all five producers
		//   feed one `invalidateTransport(...)` result straight into
		//   `scheduleTransportCleanup`/`finishTransportTermination`, so the value
		//   reaped here is unaliased and reaped exactly once.
		nonisolated(unsafe) let terminationSnapshot = terminatingTransport.snapshot
		let diagnostics = host.diagnostics
		let logger: @Sendable (String) -> Void
		if config.enableDebugLogging {
			logger = { diagnostics("[CodexAppServer] \($0)") }
		} else {
			logger = { _ in }
		}
		await CodexAppServerProcessTransport.finishTermination(
			terminationSnapshot,
			terminationPolicy: host.terminationPolicy(),
			logger: logger
		)
	}

	/// Delay before retrying a failed request, or nil if it should not be retried.
	/// Retries only overloaded (`-32001`) responses while attempts remain.
	public static func retryDelay(for error: Error, attempt: Int, policy: CodexBackoffPolicy) -> TimeInterval? {
		policy.retryDelay(for: error, attempt: attempt)
	}

	/// `sending` result: the returned dictionary is decoded fresh from this
	/// call's app-server response and is not retained by the client, so handing
	/// it out of the actor transfers sole ownership. Allows host authentication adapters to forward a freshly decoded result. Compile-time only — isolation and
	/// retry behavior are unchanged.
	public func request(method: String, params: [String: Any]?, timeout: TimeInterval? = nil) async throws -> sending [String: Any] {
		var attempt = 0
		while true {
			do {
				return try await sendRequestOnce(method: method, params: params, timeout: timeout)
			} catch {
				guard let delay = Self.retryDelay(for: error, attempt: attempt, policy: config.backoffPolicy) else {
					throw error
				}
				attempt += 1
				try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			}
		}
	}

	private func recordAdmission(_ admission: CodexExperimentalAdmission, generation: UInt64) {
		experimentalAdmissionHistory.append(
			CodexExperimentalAdmissionRecord(
				transportGeneration: generation,
				requirements: admission.requirements,
				reason: admission.reason
			)
		)
		if experimentalAdmissionHistory.count > Self.maxAdmissionHistoryCount {
			experimentalAdmissionHistory.removeFirst(
				experimentalAdmissionHistory.count - Self.maxAdmissionHistoryCount
			)
		}
	}

	/// `sending` result for the same reason `request(method:params:timeout:)`
	/// above declares one, and it is what lets that method forward this value:
	/// the dictionary is produced by the `CheckedContinuation` below, which
	/// `CodexRPCRequestStore` resumes with a payload decoded fresh from this
	/// one response. The client stores no reference to it.
	private func sendRequestOnce(method: String, params: [String: Any]?, timeout: TimeInterval? = nil) async throws -> sending [String: Any] {
		try Task.checkCancellation()
		guard transport.hasProcess else { throw ClientError.processNotRunning }
		// Fail closed: experimental-lane surface never crosses a transport
		// whose frozen admission does not name its requirement.
		if let required = CodexExperimentalSurface.requirement(
			forMethod: method,
			paramKeys: Set((params ?? [:]).keys)
		), experimentalAdmission?.admits(required) != true {
			throw ClientError.experimentalRequirementNotAdmitted(
				method: method,
				requirement: required.rawValue
			)
		}
		let requestID = requestStore.makeRequestID()
		let generation = transport.generation
		let deadline = timeout ?? config.requestTimeout
		var payload: [String: Any] = [
			"method": method,
			"id": Int(requestID) ?? requestID
		]
		if let params {
			payload["params"] = params
		}
		// `withCheckedThrowingContinuation` hands its value back `sending`, but
		// `withTaskCancellationHandler` — which has to wrap it so a cancelled caller
		// stops waiting — returns a plain `Return`. Without the carrier the response
		// would arrive merged into this actor's region and could no longer satisfy
		// the `sending` result this method (and its host authentication adapter) declares. Nothing about the request path changes.
		let response = try await withTaskCancellationHandler {
			ResponseHandoff(try await withCheckedThrowingContinuation { continuation in
				requestStore.register(
					id: requestID,
					metadata: .init(method: method, transportGeneration: generation),
					continuation: continuation
				)
				if let deadline {
					requestStore.scheduleTimeout(for: requestID, after: deadline) { [weak self] id, timeout in
						await self?.timeoutRequest(id: id, after: timeout)
					}
				}
				if Task.isCancelled {
					requestStore.cancelIfPresent(id: requestID)
					return
				}
				do {
					try sendJSONLine(payload, method: method)
				} catch {
					requestStore.resolveFailure(id: requestID, error: error)
				}
			})
		} onCancel: {
			Task { await self.cancelPendingRequestIfPresent(id: requestID) }
		}
		return response.take()
	}

	/// One-shot carrier for a decoded app-server response.
	///
	/// `@unchecked Sendable` invariant, verified against its single use in
	/// `sendRequestOnce(method:params:timeout:)`: `payload` is a `let` initialised
	/// once from the continuation's `sending` value — so the box holds the only
	/// reference — the box is created and read inside that one method, `take()` is
	/// called exactly once on the way out, and the client stores neither the box
	/// nor the dictionary. `CodexRPCRequestStore` resumed the continuation with a
	/// payload decoded fresh from this one response and keeps no reference either.
	private final class ResponseHandoff: @unchecked Sendable {
		private let payload: [String: Any]

		init(_ payload: sending [String: Any]) {
			self.payload = payload
		}

		func take() -> sending [String: Any] {
			payload
		}
	}

	public func requestJSON(
		method: String,
		params: [String: CodexJSONValue]?,
		timeout: TimeInterval? = nil
	) async throws -> [String: CodexJSONValue] {
		let result = try await request(method: method, params: params?.mapValues { $0.toAny() }, timeout: timeout)
		return codexJSONDictionary(from: result)
	}

	/// Params for the officially-supported in-band Codex API-key login.
	public static func apiKeyLoginParams(apiKey: String) -> [String: Any] {
		["type": "apiKey", "apiKey": apiKey]
	}

	/// Officially-supported in-band Codex login with a user-supplied API key.
	/// Persists an apiKey session in Codex's own store (replacing any ChatGPT
	/// login). Opt-in; the default Codex key path is non-destructive env injection.
	public func loginWithAPIKey(_ apiKey: String) async throws {
		_ = try await request(
			method: "account/login/start",
			params: Self.apiKeyLoginParams(apiKey: apiKey)
		)
	}

	public func respondToServerRequest(id: CodexAppServerRequestID, result: [String: Any]) throws {
		guard transport.hasProcess else { throw ClientError.processNotRunning }
		let payload: [String: Any] = [
			"id": id.jsonValue,
			"result": result
		]
		try sendJSONLine(payload, method: nil)
	}

	public func respondToServerRequestError(
		id: CodexAppServerRequestID,
		code: Int = -32601,
		message: String,
		data: [String: Any]? = nil
	) throws {
		guard transport.hasProcess else { throw ClientError.processNotRunning }
		var errorObject: [String: Any] = [
			"code": code,
			"message": message
		]
		if let data {
			errorObject["data"] = data
		}
		let payload: [String: Any] = [
			"id": id.jsonValue,
			"error": errorObject
		]
		try sendJSONLine(payload, method: nil)
	}

	public func notify(method: String, params: [String: Any]?) throws {
		guard transport.hasProcess else { throw ClientError.processNotRunning }
		var payload: [String: Any] = [
			"method": method
		]
		if let params {
			payload["params"] = params
		}
		try sendJSONLine(payload, method: method)
	}

	/// Returns all models exposed by Codex app-server `model/list`, following pagination.
	public func listModels(limit: Int = 100) async throws -> [RemoteModel] {
		do {
			return try await fetchModelPages(limit: limit)
		} catch let error as ClientError {
			switch error {
			case .processNotRunning, .transportWriteFailed, .transportReadSetupFailed:
				return try await fetchModelPages(limit: limit)
			default:
				throw error
			}
		} catch {
			throw error
		}
	}

	private func fetchModelPages(limit: Int) async throws -> [RemoteModel] {
		let pageLimit = max(1, limit)
		try await startIfNeeded()

		var cursor: String?
		var seenModelIDs = Set<String>()
		var models: [RemoteModel] = []

		while true {
			let params = try CodexClientCodableBridge.dictionary(from: CodexModelListParams(limit: pageLimit, cursor: cursor))

			let result = try await request(method: "model/list", params: params)
			let page = try CodexClientCodableBridge.decode(CodexModelListResult.self, from: result)

			for entry in page.data {
				guard let id = entry.id, !id.isEmpty else { continue }
				guard seenModelIDs.insert(id).inserted else { continue }

				let model = entry.model ?? id
				let displayName = entry.displayName ?? model
				let description = entry.description ?? ""
				let isDefault = entry.isDefault ?? false
				let supportedReasoningEfforts = (entry.supportedReasoningEfforts ?? [])
					.compactMap { effort -> RemoteReasoningEffort? in
						guard !effort.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
							return nil
						}
						return RemoteReasoningEffort(reasoningEffort: effort.reasoningEffort, description: effort.description)
					}
				let upgradeInfo = entry.upgradeInfo.flatMap { payload -> CodexRemoteModelUpgradeInfo? in
					guard let target = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines),
						!target.isEmpty else {
						return nil
					}
					return CodexRemoteModelUpgradeInfo(
						model: target,
						upgradeCopy: payload.upgradeCopy,
						migrationMarkdown: payload.migrationMarkdown,
						modelLink: payload.modelLink
					)
				}
				models.append(
					RemoteModel(
						id: id,
						model: model,
						displayName: displayName,
						description: description,
						isDefault: isDefault,
						supportedReasoningEfforts: supportedReasoningEfforts,
						defaultReasoningEffort: entry.defaultReasoningEffort,
						serviceTierIDs: (entry.serviceTiers ?? []).compactMap { tier in
							guard let id = tier.id, !id.isEmpty else { return nil }
							return id
						},
						upgradeModelID: entry.upgrade,
						upgradeInfo: upgradeInfo
					)
				)
			}

			let nextCursor = page.nextCursor
			guard let nextCursor, !nextCursor.isEmpty, nextCursor != cursor else {
				break
			}
			cursor = nextCursor
		}

		return models
	}

	/// Stable client capabilities, kept strictly separate from experimental
	/// admission. Empty today; anything added here must be a STABLE
	/// initialize capability (never `experimentalApi`).
	///
	/// Computed rather than stored: `[String: Any]` is not `Sendable`, so as
	/// static storage it would be shared mutable state under Swift 6. The single
	/// caller already copies it into a local `var` before mutating, so handing
	/// back a fresh value each time is indistinguishable — and it keeps the
	/// literal as the one place a stable capability gets declared.
	private static var stableClientCapabilities: [String: Any] { [:] }

	private func initializeIfNeeded() async throws {
		if isInitialized {
			return
		}
		let generation = transport.generation
		let clientInfo: [String: Any] = [
			"name": host.clientIdentity.name,
			"title": host.clientIdentity.title,
			"version": host.clientIdentity.version
		]
		// The admission was frozen at spawn, before this initialize; a
		// stable-only transport omits `experimentalApi` entirely (and, while
		// there are no stable capabilities, the whole `capabilities` object).
		let admission = experimentalAdmission ?? .stableOnly
		var capabilities = Self.stableClientCapabilities
		if !admission.isStableOnly {
			capabilities["experimentalApi"] = true
		}
		var params: [String: Any] = ["clientInfo": clientInfo]
		if !capabilities.isEmpty {
			params["capabilities"] = capabilities
		}
		_ = try await request(method: "initialize", params: params)
		try Task.checkCancellation()
		guard generation == transport.generation, !transport.isTerminated else {
			throw ClientError.processNotRunning
		}
		try notify(method: "initialized", params: [:])
		isInitialized = true
	}

	private func performStartupIfNeeded() async throws {
		if !transport.hasProcess {
			try await startProcess()
		}
		try await initializeIfNeeded()
	}

	private func startProcess() async throws {
		let launch = try await prepareCurrentLaunch()
		let spawnedPID = try transport.spawn(
			CodexAppServerProcessTransport.LaunchSpec(
				command: launch.command,
				arguments: launch.arguments,
				environment: launch.environment,
				workingDirectory: launch.workingDirectory
			)
		)
		// Freeze the experimental admission for this transport generation —
		// before initialize, immutable until invalidation. Concurrent
		// startIfNeeded callers share the one startup task, so they all see
		// this single frozen snapshot.
		let admission = CodexExperimentalAdmission(
			requirements: config.experimentalRequirements,
			reason: experimentalRequirementsReason
		)
		experimentalAdmission = admission
		recordAdmission(admission, generation: transport.generation)
		stdoutDecoder = CodexJSONStreamDecoder()
		let diagnostics = host.diagnostics
		var stderrLogger: (@Sendable (String) -> Void)?
		if config.enableDebugLogging {
			stderrLogger = { line in diagnostics("[CodexAppServer][stderr] \(line)") }
		}
		let generation = transport.generation
		let onStdoutChunk: @Sendable (Data) async -> Void = { [weak self] chunk in
			await self?.handleStdoutChunk(chunk, generation: generation)
		}
		let onStdoutEOF: @Sendable (UInt64) async -> Void = { [weak self] generation in
			await self?.handleStdoutEOF(generation: generation)
		}
		do {
			try transport.startReaders(
				onStdoutChunk: onStdoutChunk,
				onStdoutEOF: onStdoutEOF,
				stderrLogger: stderrLogger
			)
		} catch {
			let clientError = transportReadSetupError(stream: "process pipe", error: error)
			let terminatingTransport = invalidateTransport(
				flushStdout: false,
				requestFailure: clientError,
				reason: .readSourceSetupFailed(stream: "process pipe", errno: host.readErrorCode(error))
			)
			await finishTransportTermination(terminatingTransport)
			throw clientError
		}
		await registerExpectedAgentPIDIfNeeded(for: spawnedPID)
		guard transport.pid == spawnedPID, !transport.isTerminated else {
			throw ClientError.processNotRunning
		}
	}

	/// A host resolver may suspend while discovery or authentication completes.
	/// Retry after a concurrent config update so launch arguments and frozen
	/// admission always describe the same configuration.
	private func prepareCurrentLaunch() async throws -> LaunchSpecification {
		while true {
			try Task.checkCancellation()
			let snapshot = config
			let launch = try await host.prepareLaunch(snapshot)
			try Task.checkCancellation()
			if snapshot == config { return launch }
		}
	}

	private func handleStdoutChunk(_ data: Data, generation: UInt64) async {
		guard generation == transport.generation, !transport.isTerminated else { return }
		handleDecoderEvents(stdoutDecoder.ingest(data))
	}

	/// Called when the stdout consumer task's channel stream ends (EOF or explicit finish).
	/// Delegates to `terminateTransport` for authoritative cleanup, scoped to the
	/// transport generation that created the consumer task.
	private func handleStdoutEOF(generation: UInt64) async {
		await terminateTransport(
			flushStdout: true,
			expectedGeneration: generation,
			reason: .stdoutEOF
		)
	}

	/// Applies decoder output under this actor: routes decoded objects,
	/// translates diagnostics (debug logging + budget-exhaustion teardown).
	private func handleDecoderEvents(_ events: [CodexJSONStreamDecoder.Event]) {
		for event in events {
			switch event {
			case .object(let json):
				route(json)
			case .diagnostic(let diagnostic):
				handleDecoderDiagnostic(diagnostic)
			}
		}
	}

	private func handleDecoderDiagnostic(_ diagnostic: CodexJSONStreamDecoder.Diagnostic) {
		if case .recoveryBudgetExhausted = diagnostic {
			let generation = transport.generation
			if config.enableDebugLogging {
				host.diagnostics("[CodexAppServer] Decode recovery budget exhausted for generation \(generation); terminating poisoned transport")
			}
			Task { [generation] in
				await self.terminateTransport(
					flushStdout: false,
					expectedGeneration: generation,
					reason: .decodeRecoveryBudgetExceeded(generation: generation)
				)
			}
			return
		}
		guard config.enableDebugLogging else { return }
		switch diagnostic {
		case .framerOverflow(let droppedBytes, let retainedBytes, let tailSample):
			if let tailSample {
				host.diagnostics("[CodexAppServer] stdout LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes, tail sample: \(tailSample)")
			} else {
				host.diagnostics("[CodexAppServer] stdout LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes")
			}
		case .nonJSONCandidateQuoteStateReset:
			host.diagnostics("[CodexAppServer] stdout LineFramer reset quote state for non-JSON candidate")
		case .recoveredConcatenatedObjects(let recovered, let segments):
			host.diagnostics("[CodexAppServer] Recovered \(recovered)/\(segments) JSON segment(s) from corrupted line")
		case .recoveredEmbeddedTail(let offset):
			host.diagnostics("[CodexAppServer] Recovered embedded JSON tail at offset \(offset)")
		case .recoveredControlCharacters:
			host.diagnostics("[CodexAppServer] Recovered JSON by escaping control characters inside JSON strings")
		case .decodeFailedNoRecovery(let preview):
			host.diagnostics("[CodexAppServer] Failed to decode JSON line (no recovery): \(preview)")
		case .recoveryBudgetExhausted:
			break
		}
	}

	/// Routes a decoded inbound JSON-RPC object: resolves pending requests via
	/// the request store, broadcasts notifications/server requests to
	/// subscribers. Classification lives in CodexJSONRPCCodec.
	private func route(_ json: [String: Any]) {
		guard let message = CodexJSONRPCCodec.classify(json) else { return }
		switch message {
		case .response(let id, let result):
			if requestStore.resolveSuccess(id: id, result: result), config.enableDebugLogging {
				host.diagnostics("[CodexAppServer] Response for request \(id)")
			}
		case .errorResponse(let id, let code, let message):
			let error: ClientError = code.map { ClientError.rpcError(code: $0, message: message) }
				?? .requestFailed(message)
			if requestStore.resolveFailure(id: id, error: error), config.enableDebugLogging {
				host.diagnostics("[CodexAppServer] Error for request \(id): \(message)")
			}
		case .serverRequest(let id, let method, let params):
			if config.enableDebugLogging {
				host.diagnostics("[CodexAppServer] Server request: \(method) -> broadcasting to \(serverRequestContinuations.count) listeners")
			}
			broadcastServerRequest(id: id, method: method, params: codexJSONDictionary(from: params))
		case .notification(let method, let params):
			if config.enableDebugLogging {
				host.diagnostics("[CodexAppServer] Notification: \(method) -> broadcasting to \(notificationContinuations.count) listeners")
			}
			broadcastNotification(method: method, params: codexJSONDictionary(from: params))
		case .unroutableResponse(let id):
			requestStore.resolveFailure(id: id, error: ClientError.invalidResponse)
		}
	}

	private func broadcastNotification(method: String, params: [String: CodexJSONValue]) {
		for continuation in notificationContinuations.values {
			continuation.yield(Notification(method: method, params: params))
		}
	}

	private func broadcastServerRequest(id: CodexAppServerRequestID, method: String, params: [String: CodexJSONValue]) {
		let request = ServerRequest(id: id, method: method, params: params)
		for continuation in serverRequestContinuations.values {
			continuation.yield(request)
		}
	}

	private func codexJSONDictionary(from value: [String: Any]) -> [String: CodexJSONValue] {
		var output: [String: CodexJSONValue] = [:]
		for (key, value) in value {
			if let converted = CodexJSONValue.from(value) {
				output[key] = converted
			}
		}
		return output
	}

	/// Writes a single JSON-RPC line to stdin as an atomic frame (payload + newline).
	///
	/// Combining payload and newline into a single write prevents pipe interleaving
	/// that could theoretically occur with two separate writes.
	///
	/// Related:
	/// - ClaudeNativeProcessSessionController.sendLine (reference atomic write pattern)
	private func sendJSONLine(_ payload: [String: Any], method: String?) throws {
		guard transport.hasProcess else { throw ClientError.processNotRunning }
		let frame = try CodexJSONRPCCodec.frame(payload)
		if config.enableDebugLogging {
			if let line = String(data: frame.dropLast(), encoding: .utf8) {
				host.diagnostics("[CodexAppServer] -> \(line)")
			}
		}
		let generation = transport.generation
		do {
			try transport.writeFrame(frame)
		} catch CodexAppServerProcessTransport.WriteFailure.transportUnavailable {
			throw ClientError.processNotRunning
		} catch let error as FDWriteError {
			let failure = ClientError.transportWriteFailed(
				message: transportWriteFailureMessage(method: method, errno: error.errnoValue),
				errno: error.errnoValue
			)
			scheduleTransportCleanup(
				invalidateTransport(
					flushStdout: false,
					expectedGeneration: generation,
					requestFailure: failure,
					reason: .stdinWrite(method: method, errno: error.errnoValue)
				)
			)
			throw failure
		} catch {
			let failure = ClientError.transportWriteFailed(
				message: transportWriteFailureMessage(method: method, errno: nil),
				errno: nil
			)
			scheduleTransportCleanup(
				invalidateTransport(
					flushStdout: false,
					expectedGeneration: generation,
					requestFailure: failure,
					reason: .stdinWrite(method: method, errno: nil)
				)
			)
			throw failure
		}
	}

	private func transportWriteFailureMessage(method: String?, errno: Int32?) -> String {
		let operation = method ?? "transport write"
		if let errno {
			let message = String(cString: strerror(errno))
			return "Codex app-server stdin write failed during \(operation): \(message)"
		}
		return "Codex app-server stdin write failed during \(operation)."
	}

	private func transportReadSetupError(stream: String, error: Error) -> ClientError {
		let errnoValue = host.readErrorCode(error)
		if let errnoValue {
			let message = String(cString: strerror(errnoValue))
			return .transportReadSetupFailed(
				message: "Codex app-server \(stream) reader failed to start: \(message)",
				errno: errnoValue
			)
		}
		return .transportReadSetupFailed(
			message: "Codex app-server \(stream) reader failed to start: \(error.localizedDescription)",
			errno: nil
		)
	}


	private func timeoutRequest(id: String, after timeout: TimeInterval) async {
		requestStore.fireTimeout(
			id: id,
			after: timeout,
			poison: { metadata in
				guard CodexRequestTimeoutPolicy.shouldPoisonTransportOnTimeout(method: metadata.method) else { return }
				scheduleTransportCleanup(
					invalidateTransport(
						flushStdout: false,
						expectedGeneration: metadata.transportGeneration,
						requestFailure: .processNotRunning,
						reason: .timeout(method: metadata.method, requestID: id)
					)
				)
			},
			makeError: { ClientError.requestFailed("Request timed out after \($0)s") }
		)
	}

	private func cancelPendingRequestIfPresent(id: String) {
		requestStore.cancelIfPresent(id: id)
	}

	private func removeNotificationContinuation(_ id: UUID) {
		notificationContinuations.removeValue(forKey: id)
	}

	private func removeServerRequestContinuation(_ id: UUID) {
		serverRequestContinuations.removeValue(forKey: id)
	}

#if DEBUG
	public func debugProcessID() -> pid_t? {
		transport.pid
	}

	public func debugIsProcessRunning() -> Bool {
		transport.hasProcess
	}

	public func debugNextRequestID() -> Int {
		requestStore.peekNextRequestID
	}

	public func debugTransportGeneration() -> UInt64 {
		transport.generation
	}

	public func debugLastTransportTerminationReason() -> TransportTerminationReason? {
		lastTransportTerminationReason
	}

	public static func debugDefaultProcessAppearsAlive(_ process: SpawnedProcess) -> Bool {
		CodexAppServerProcessTransport.defaultProcessAppearsAlive(process)
	}

	/// Attempts for the CURRENT transport generation (the decoder instance is
	/// replaced per generation; other generations always report 0).
	public func debugDecodeRecoveryAttempts(generation: UInt64? = nil) -> Int {
		if let generation, generation != transport.generation { return 0 }
		return stdoutDecoder.recoveryAttempts
	}

	public func debugIngestStdoutChunk(_ data: Data, generation: UInt64) async {
		await handleStdoutChunk(data, generation: generation)
	}

	public func debugIngestRawStdoutLine(_ line: Data) {
		handleDecoderEvents(stdoutDecoder.ingestLine(line))
	}

	public static func debugMaxDecodeRecoveryAttemptsPerGeneration() -> Int {
		CodexJSONStreamDecoder.maxRecoveryAttemptsPerInstance
	}

	public func debugPendingRequestCount() -> Int {
		requestStore.pendingCount
	}

	public func debugTimeoutTaskCount() -> Int {
		requestStore.timeoutTaskCount
	}

	public func debugInstallTestTransport() {
		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()
		transport.debugInstallProcess(
			SpawnedProcess(
				pid: pid_t.max,
				stdin: stdinPipe.fileHandleForWriting,
				stdinDescriptor: stdinPipe.fileHandleForWriting.fileDescriptor,
				stdout: stdoutPipe.fileHandleForReading,
				stderr: stderrPipe.fileHandleForReading
			)
		)
		isInitialized = true
		lastTransportTerminationReason = nil
		experimentalAdmission = .stableOnly
		stdoutDecoder = CodexJSONStreamDecoder()
	}

	/// Overrides the frozen admission on a debug-installed test transport.
	public func debugSetExperimentalAdmission(_ admission: CodexExperimentalAdmission) {
		experimentalAdmission = admission
	}

#endif
}
