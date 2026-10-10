import Foundation
import AgentACPProtocol
import OpenCodeRuntimeKit

/// Session state and orchestration confined to one owner actor. Async entry points
/// inherit that actor explicitly; synchronous observers see in-flight binding/replay
/// state before requests are sent, without mirroring a second authority in the host.
public final class ACPSessionLifecycle {
	public typealias RPC = @Sendable (String, ACPJSONObject) async throws -> ACPJSONObject
	public struct Errors: Sendable {
		public let closed: @Sendable () -> any Error
		public let requestFailed: @Sendable (String) -> any Error
		public let protocolViolation: @Sendable (String) -> any Error
		public init(closed: @escaping @Sendable () -> any Error,
			requestFailed: @escaping @Sendable (String) -> any Error,
			protocolViolation: @escaping @Sendable (String) -> any Error) {
			self.closed = closed; self.requestFailed = requestFailed; self.protocolViolation = protocolViolation
		}
	}
	public enum OperationError: Error { case lifecycleBusy, alreadyInitialized }
	public struct Initialize: Sendable {
		public let clientName: String
		public let clientVersion: String
		public let protocolVersion: Int
		public let clientCapabilities: ACPJSONObject
		public init(clientName: String, clientVersion: String, protocolVersion: Int = 1, clientCapabilities: ACPJSONObject) {
			self.clientName = clientName; self.clientVersion = clientVersion; self.protocolVersion = protocolVersion; self.clientCapabilities = clientCapabilities
		}
	}
	public struct Configuration: Sendable {
		public enum Mode: Sendable { case new, load(String) }
		public let mode: Mode
		public let workingDirectory: String
		public let mcpServers: [ACPJSONObject]
		public let providerName: String
		public init(mode: Mode, workingDirectory: String, mcpServers: [ACPJSONObject], providerName: String) {
			self.mode = mode; self.workingDirectory = workingDirectory; self.mcpServers = mcpServers; self.providerName = providerName
		}
	}
	public struct OpenResult: Sendable {
		public let sessionID: String
		public let restoredExistingSession: Bool
		public let invalidatedResumeSessionID: String?
	}
	public struct SessionList: Sendable {
		public let sessions: [ACPJSONObject]
		public let nextCursor: String?
	}
	public enum Event: Sendable {
		case log(String), info(String), phaseStarted(String), phaseCompleted(String)
		case initialized
		case modelsChanged(ACPDiscoveredModels?)
	}
	private let errors: Errors
	private var generation: UInt64 = 0
	private var retired = false
	private var admissionCompleted = false
	private var exclusiveOperation: UUID?
	private var modeRevision: UInt64 = 0
	private var modelRevision: UInt64 = 0
	public private(set) var sessionID: String?
	public private(set) var inFlightSessionID: String?
	public private(set) var replaySuppressed = false
	public private(set) var invalidatedResumeSessionID: String?
	public private(set) var capabilitySnapshot: OpenCodeCapabilitySnapshot?
	public private(set) var effectiveCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities?
	public private(set) var currentModeID: String?
	public private(set) var modeSelectionSupported = false
	public private(set) var advertisedModeIDs: Set<String>?
	public private(set) var models: ACPDiscoveredModels?
	public var gatingCapabilities: OpenCodeCapabilitySnapshot.SessionCapabilities? {
		admissionCompleted ? (effectiveCapabilities ?? capabilitySnapshot?.sessionCapabilities) : nil
	}
	public var loadSessionSupported: Bool { gatingCapabilities?.loadSession == true }
	public init(errors: Errors) { self.errors = errors }

	/// Retires suspended commands immediately, retaining recovery identity/capabilities.
	public func invalidate() {
		retired = true; generation &+= 1; exclusiveOperation = nil
		inFlightSessionID = nil; replaySuppressed = false
	}
	public func clearConfigurationAfterShutdown() {
		models = nil; currentModeID = nil; modeSelectionSupported = false; advertisedModeIDs = nil
		replaySuppressed = false
	}
	public func endReplayWindow() { replaySuppressed = false }
	public func boundSessionID(_ candidate: String?) -> String? {
		guard let bound = sessionID ?? inFlightSessionID, !bound.isEmpty,
			let candidate, candidate.utf8.elementsEqual(bound.utf8) else { return nil }
		return bound
	}
	private func check(_ stamp: UInt64) throws {
		guard !retired, generation == stamp else { throw errors.closed() }
	}
	private func beginExclusive() throws -> (UInt64, UUID) {
		try check(generation)
		guard exclusiveOperation == nil else { throw OperationError.lifecycleBusy }
		let token = UUID(); exclusiveOperation = token
		return (generation, token)
	}
	private func endExclusive(_ token: UUID) { if exclusiveOperation == token { exclusiveOperation = nil } }

	public func initialize(_ configuration: Initialize, rpc: RPC,
		selectAuthentication: @Sendable ([String]) async throws -> String?,
		admit: @Sendable (OpenCodeCapabilitySnapshot) async throws -> OpenCodeCapabilitySnapshot.SessionCapabilities?,
		onEvent: (Event) -> Void, isolation: isolated (any Actor)? = #isolation) async throws {
		let (stamp, token) = try beginExclusive(); defer { endExclusive(token) }
		guard capabilitySnapshot == nil else { throw OperationError.alreadyInitialized }
		onEvent(.log("ACP initialize")); onEvent(.phaseStarted("initialize"))
		try check(stamp)
		let response = try await rpc("initialize", .init(object: ["protocolVersion": configuration.protocolVersion,
			"clientInfo": ["name": configuration.clientName, "version": configuration.clientVersion],
			"clientCapabilities": configuration.clientCapabilities.dictionary()]))
		try check(stamp)
		onEvent(.phaseCompleted("initialize")); onEvent(.initialized); try check(stamp)
		let object = try response.dictionary()
		// Preserve the legacy authentication selector's methodId alias and trimming;
		// capability evidence is decoded independently by the strict runtime snapshot.
		let auth = (object["authMethods"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
			guard let raw = (entry["id"] as? String) ?? (entry["methodId"] as? String) else { return nil }
			let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
			return value.isEmpty ? nil : value
		}
		let selected = try await selectAuthentication(auth); try check(stamp)
		if let selected {
			onEvent(.log("ACP authenticate via \(selected)")); onEvent(.phaseStarted("authenticate"))
			_ = try await rpc("authenticate", .init(object: ["methodId": selected])); try check(stamp)
			onEvent(.phaseCompleted("authenticate"))
		}
		let snapshot = OpenCodeCapabilitySnapshot.decode(initializeResponse: object)
		capabilitySnapshot = snapshot
		onEvent(.phaseStarted("post-initialize-admission")); try check(stamp)
		let effective = try await admit(snapshot); try check(stamp)
		if let effective {
			let advertised = snapshot.sessionCapabilities
			effectiveCapabilities = .init(loadSession: advertised.loadSession && effective.loadSession,
				listSessions: advertised.listSessions && effective.listSessions,
				resumeSession: advertised.resumeSession && effective.resumeSession,
				closeSession: advertised.closeSession && effective.closeSession,
				unstableForkSession: advertised.unstableForkSession && effective.unstableForkSession)
		}
		admissionCompleted = true
		onEvent(.phaseCompleted("post-initialize-admission")); try check(stamp)
	}

	public func open(_ configuration: Configuration, rpc: RPC,
		shouldOpenFresh: @Sendable (any Error) async -> Bool, onEvent: (Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws -> OpenResult {
		let (stamp, token) = try beginExclusive(); defer { endExclusive(token) }
		guard admissionCompleted else { throw errors.requestFailed("ACP runtime capabilities are unavailable before initialize.") }
		switch configuration.mode {
		case .new: return try await openNew(configuration, stamp: stamp, rpc: rpc, onEvent: onEvent, isolation: isolation)
		case .load(let raw):
			guard let identity = ACPSessionIdentity.validated(raw) else {
				onEvent(.log("Persisted ACP session id is invalid; opening a fresh session instead"))
				onEvent(.info("Persisted ACP session id failed validation; opening a fresh session."))
				replaySuppressed = false
				return try await openNew(configuration, stamp: stamp, rpc: rpc, onEvent: onEvent, isolation: isolation)
			}
			if gatingCapabilities?.resumeSession == true {
				do {
					inFlightSessionID = identity
					defer { if generation == stamp { inFlightSessionID = nil } }
					onEvent(.log("Starting ACP session/resume for \(identity)")); onEvent(.phaseStarted("session/resume"))
					try await performResume(identity, configuration: configuration, stamp: stamp, rpc: rpc, onEvent: onEvent, isolation: isolation)
					onEvent(.phaseCompleted("session/resume")); onEvent(.log("Completed ACP session/resume sessionID=\(identity)"))
					return .init(sessionID: identity, restoredExistingSession: true, invalidatedResumeSessionID: nil)
				} catch {
					try check(stamp)
					onEvent(.log("ACP session/resume failed for \(identity): \(error.localizedDescription); falling back to session/load"))
					onEvent(.info("ACP session/resume failed; falling back to session/load."))
				}
			}
			guard loadSessionSupported else {
				replaySuppressed = false
				throw errors.requestFailed("ACP runtime does not support session/load for existing session \(identity).")
			}
			do {
				replaySuppressed = true; inFlightSessionID = identity
				defer { if generation == stamp { replaySuppressed = false; inFlightSessionID = nil } }
				onEvent(.log("Starting ACP session/load mcpServers=\(configuration.mcpServers.count)")); onEvent(.phaseStarted("session/load"))
				try check(stamp)
				let response = try await rpc("session/load", sessionParameters(identity, configuration)); try check(stamp)
				try installConfiguration(response, onEvent: onEvent); try check(stamp)
				onEvent(.phaseCompleted("session/load")); onEvent(.log("Completed ACP session/load sessionID=\(identity)")); try check(stamp)
				sessionID = identity
				return .init(sessionID: identity, restoredExistingSession: true, invalidatedResumeSessionID: nil)
			} catch {
				try check(stamp); replaySuppressed = false
				onEvent(.log("ACP session/load failed for \(identity): \(error.localizedDescription)"))
				let fresh = await shouldOpenFresh(error); try check(stamp)
				guard fresh else { throw error }
				invalidatedResumeSessionID = identity
				onEvent(.log("Falling back to ACP session/new after missing \(configuration.providerName) session \(identity)"))
				onEvent(.info("ACP session/load could not find \(configuration.providerName) session \(identity); opening a fresh session."))
				let result = try await openNew(configuration, stamp: stamp, rpc: rpc, onEvent: onEvent, isolation: isolation)
				return .init(sessionID: result.sessionID, restoredExistingSession: false, invalidatedResumeSessionID: identity)
			}
		}
	}
	private func openNew(_ configuration: Configuration, stamp: UInt64, rpc: RPC,
		onEvent: (Event) -> Void, isolation: isolated (any Actor)?) async throws -> OpenResult {
		replaySuppressed = false
		onEvent(.log("Starting ACP session/new mcpServers=\(configuration.mcpServers.count)")); onEvent(.phaseStarted("session/new"))
		try check(stamp)
		let response = try await rpc("session/new", baseParameters(configuration)); try check(stamp)
		let object = try response.dictionary()
		guard let raw = object["sessionId"] as? String else { throw errors.protocolViolation("session/new response missing sessionId") }
		guard let identity = ACPSessionIdentity.validated(raw) else { throw errors.protocolViolation("session/new returned an invalid sessionId") }
		try installConfiguration(response, onEvent: onEvent); try check(stamp)
		onEvent(.phaseCompleted("session/new")); onEvent(.log("Completed ACP session/new sessionID=\(identity)")); try check(stamp)
		sessionID = identity
		return .init(sessionID: identity, restoredExistingSession: false, invalidatedResumeSessionID: nil)
	}
	private func baseParameters(_ configuration: Configuration) throws -> ACPJSONObject {
		try .init(object: ["cwd": configuration.workingDirectory, "mcpServers": configuration.mcpServers.map { try $0.dictionary() }])
	}
	private func sessionParameters(_ identity: String, _ configuration: Configuration) throws -> ACPJSONObject {
		var object = try baseParameters(configuration).dictionary(); object["sessionId"] = identity
		return try .init(object: object)
	}
	private func require(_ path: KeyPath<OpenCodeCapabilitySnapshot.SessionCapabilities, Bool>, name: String) throws {
		guard let caps = gatingCapabilities else { throw errors.requestFailed("ACP runtime capabilities are unavailable before initialize.") }
		guard caps[keyPath: path] else { throw errors.requestFailed("ACP runtime does not advertise the '\(name)' session capability.") }
	}
	public func list(configuration: Configuration, cursor: String?, rpc: RPC,
		isolation: isolated (any Actor)? = #isolation) async throws -> SessionList {
		try check(generation); try require(\.listSessions, name: "list"); let stamp = generation
		var params: [String: Any] = [:]
		if !configuration.workingDirectory.isEmpty { params["cwd"] = configuration.workingDirectory }
		if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
		let response = try await rpc("session/list", .init(object: params)); try check(stamp)
		let object = try response.dictionary()
		return .init(sessions: try (object["sessions"] as? [[String: Any]] ?? []).map { try .init(object: $0) }, nextCursor: object["nextCursor"] as? String)
	}
	public func resume(_ raw: String, configuration: Configuration, rpc: RPC, onEvent: (Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws {
		let (stamp, token) = try beginExclusive(); defer { endExclusive(token) }
		try require(\.resumeSession, name: "resume")
		guard let identity = ACPSessionIdentity.validated(raw) else { throw errors.requestFailed("session/resume requires a valid provider session ID.") }
		try await performResume(identity, configuration: configuration, stamp: stamp, rpc: rpc, onEvent: onEvent, isolation: isolation)
	}
	private func performResume(_ identity: String, configuration: Configuration, stamp: UInt64, rpc: RPC,
		onEvent: (Event) -> Void, isolation: isolated (any Actor)?) async throws {
		try check(stamp)
		let response = try await rpc("session/resume", sessionParameters(identity, configuration)); try check(stamp)
		sessionID = identity; try installConfiguration(response, onEvent: onEvent); try check(stamp)
	}
	public func close(rpc: RPC, isolation: isolated (any Actor)? = #isolation) async throws {
		try check(generation); try require(\.closeSession, name: "close")
		guard let sessionID else { return }
		let stamp = generation
		_ = try await rpc("session/close", .init(object: ["sessionId": sessionID])); try check(stamp)
	}
	public func setMode(_ raw: String, rpc: RPC, isolation: isolated (any Actor)? = #isolation) async throws {
		try check(generation)
		guard let sessionID else { throw errors.requestFailed("ACP session is not open.") }
		let mode = raw.trimmingCharacters(in: .whitespacesAndNewlines); guard !mode.isEmpty else { return }
		if !modeSelectionSupported {
			if mode.caseInsensitiveCompare("default") == .orderedSame { modeRevision &+= 1; currentModeID = mode; return }
			throw errors.requestFailed("ACP runtime does not advertise session mode switching support.")
		}
		guard advertisedModeIDs?.contains(mode.lowercased()) == true else {
			let available = advertisedModeIDs?.sorted().joined(separator: ", ") ?? ""
			throw errors.requestFailed("ACP runtime does not advertise session mode '\(mode)'. Available modes: \(available.isEmpty ? "none" : available).")
		}
		modeRevision &+= 1; let revision = modeRevision, stamp = generation
		if currentModeID?.caseInsensitiveCompare(mode) == .orderedSame { return }
		do { _ = try await rpc("session/set_mode", .init(object: ["sessionId": sessionID, "modeId": mode])) }
		catch { try check(stamp); guard revision == modeRevision else { return }; throw error }
		try check(stamp)
		guard revision == modeRevision else { return }; currentModeID = mode
	}
	public func setModelConfiguration(_ value: String, rpc: RPC, onEvent: (Event) -> Void,
		isolation: isolated (any Actor)? = #isolation) async throws {
		try check(generation)
		guard let sessionID else { throw errors.requestFailed("ACP session is not open.") }
		modelRevision &+= 1; let revision = modelRevision, stamp = generation
		let response: ACPJSONObject
		do { response = try await rpc("session/set_config_option", .init(object: ["sessionId": sessionID, "configId": "model", "value": value])) }
		catch { try check(stamp); guard revision == modelRevision else { return }; throw error }
		try check(stamp)
		guard modelRevision == revision else { return }; try installModels(response, onEvent: onEvent)
	}
	private func installConfiguration(_ response: ACPJSONObject, onEvent: (Event) -> Void) throws {
		modeRevision &+= 1; modelRevision &+= 1
		let object = try response.dictionary()
		if let modes = object["modes"] as? [String: Any] {
			currentModeID = modes["currentModeId"] as? String; modeSelectionSupported = true
			let raw = modes["availableModes"] ?? modes["available"] ?? modes["modeOptions"]
			let ids: [String]
			if let strings = raw as? [String] { ids = strings.compactMap(Self.normalizedMode) }
			else if let objects = raw as? [[String: Any]] { ids = objects.compactMap { Self.normalizedMode(($0["id"] as? String) ?? ($0["modeId"] as? String) ?? ($0["name"] as? String)) } }
			else { ids = [] }
			advertisedModeIDs = Set(ids.map { $0.lowercased() })
		} else { currentModeID = nil; modeSelectionSupported = false; advertisedModeIDs = nil }
		try installModels(response, onEvent: onEvent)
	}
	private func installModels(_ response: ACPJSONObject, onEvent: (Event) -> Void) throws {
		models = ACPModelMetadata.decode(from: try response.dictionary()) {
			onEvent(.info("ACP session response included model/config option metadata, but no usable model entries were found."))
		}
		onEvent(.modelsChanged(models))
	}
	private static func normalizedMode(_ raw: String?) -> String? {
		guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
		return value
	}
}
