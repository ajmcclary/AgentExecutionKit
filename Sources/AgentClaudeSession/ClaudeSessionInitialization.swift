import Foundation
import AgentClaudeProtocol

/// Actor-confined initialization and native settings authority. Async operations
/// inherit the host executor. Model/effort resolution, admission, permission mode,
/// process ownership and observations are explicit host inputs.
public final class ClaudeSessionInitialization {
	public enum ApplyOutcome: Sendable, Equatable {
		case applied, noProcess, superseded, pendingInitialization, noRequest
		public var establishesAcceptance: Bool { self == .applied }
	}
	public enum Source: Sendable { case initialization, liveUpdate }
	public enum Event: Sendable {
		case pending(ClaudeProtocolJSONObject?)
		case applied(request: ClaudeProtocolJSONObject, response: ClaudeProtocolJSONObject, source: Source)
	}
	public typealias RPC = @Sendable (ClaudeProtocolJSONObject, TimeInterval?) async throws -> ClaudeProtocolJSONObject
	private var scope = UUID()
	private var latestIntent: UInt64 = 0
	private var storedGeneration: UInt64 = 0
	private let retiredError: @Sendable () -> any Error
	public private(set) var isInitialized = false
	public private(set) var hasCompletedInitialSettings = false
	public private(set) var pendingSettings: ClaudeProtocolJSONObject?
	public init(retiredError: @escaping @Sendable () -> any Error) { self.retiredError = retiredError }

	/// Teardown retires async authority while retaining the last resolved settings,
	/// matching the native controller. A new launch resets its version counters.
	public func retire() { scope = UUID(); isInitialized = false; hasCompletedInitialSettings = false }
	public func beginLaunch() { retire(); latestIntent = 0; storedGeneration = 0 }
	public func storeSettings(_ request: ClaudeProtocolJSONObject?) {
		storedGeneration &+= 1; pendingSettings = request
	}
	private func requireCurrent(_ stamp: UUID) throws {
		guard stamp == scope else { throw retiredError() }
	}

	/// Response observation, initial settings, permission round trip, then admission.
	/// Readiness is never committed by a rejected or retired initialization.
	public func initialize(request: ClaudeProtocolJSONObject, timeoutSeconds: TimeInterval?, rpc: RPC,
		onResponse: (ClaudeProtocolJSONObject) throws -> Void, observeSettings: (Event) -> Void,
		applyPermissionMode: () async throws -> Void,
		admit: (ClaudeProtocolJSONObject) async throws -> Void, onReady: () -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws {
		guard !isInitialized else { return }
		let stamp = scope
		let response = try await rpc(request, timeoutSeconds)
		try requireCurrent(stamp)
		try onResponse(response)
		try requireCurrent(stamp)
		try await applyInitialSettings(rpc: rpc, observe: observeSettings)
		try requireCurrent(stamp)
		try await applyPermissionMode()
		try requireCurrent(stamp)
		try await admit(response)
		try requireCurrent(stamp)
		isInitialized = true
		onReady()
		try requireCurrent(stamp)
	}

	public func applyLiveSettings(resolve: () async throws -> ClaudeProtocolJSONObject?,
		isProcessAvailable: () -> Bool, rpc: RPC, observe: (Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws -> ApplyOutcome {
		guard isProcessAvailable() else { return .noProcess }
		let stamp = scope
		latestIntent &+= 1
		let intent = latestIntent
		let request = try await resolve()
		guard stamp == scope, intent == latestIntent else { return .superseded }
		storeSettings(request)
		guard isProcessAvailable() else { return .noProcess }
		guard isInitialized || hasCompletedInitialSettings else {
			observe(.pending(request)); return .pendingInitialization
		}
		guard let request else { return .noRequest }
		let response = try await rpc(request, 5.0)
		guard stamp == scope else { return .superseded }
		// A real ACK in this epoch establishes acceptance even if a newer intent
		// exists. Host selection generations own rollback/reconciliation, as before.
		observe(.applied(request: request, response: response, source: .liveUpdate))
		guard stamp == scope else { return .superseded }
		return .applied
	}

	private func applyInitialSettings(rpc: RPC, observe: (Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws {
		let stamp = scope
		while true {
			try requireCurrent(stamp)
			let generation = storedGeneration
			guard let request = pendingSettings else { hasCompletedInitialSettings = true; return }
			let response = try await rpc(request, nil)
			try requireCurrent(stamp)
			observe(.applied(request: request, response: response, source: .initialization))
			try requireCurrent(stamp)
			if generation == storedGeneration { hasCompletedInitialSettings = true; return }
		}
	}
}
