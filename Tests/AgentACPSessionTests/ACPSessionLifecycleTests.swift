import Foundation
import XCTest
import AgentACPProtocol
import AgentACPSession
import OpenCodeRuntimeKit

private enum Failure: Error, Equatable { case closed, request(String), violation(String), admission, missing, resume }

@MainActor
private final class Fixture {
	let session = ACPSessionLifecycle(errors: .init(closed: { Failure.closed }, requestFailed: { Failure.request($0) }, protocolViolation: { Failure.violation($0) }))
	var calls: [(String, ACPJSONObject)] = []
	var responses: [String: [Result<ACPJSONObject, Failure>]] = [:]
	var pending: [String: CheckedContinuation<ACPJSONObject, any Error>] = [:]
	var held = Set<String>()
	var events: [ACPSessionLifecycle.Event] = []
	var binding: String?
	var replay = false
	var authMethods: [String] = []
	var auth: String?
	var effective: OpenCodeCapabilitySnapshot.SessionCapabilities?
	var denyAdmission = false
	var holdAdmission = false
	var admission: CheckedContinuation<Void, Never>?
	var rpc: ACPSessionLifecycle.RPC { { [weak self] method, params in guard let self else { throw Failure.closed }; return try await self.send(method, params) } }
	func send(_ method: String, _ params: ACPJSONObject) async throws -> ACPJSONObject {
		calls.append((method, params))
		let object = try params.dictionary()
		if method == "session/load" || method == "session/resume" {
			binding = session.boundSessionID(object["sessionId"] as? String); replay = session.replaySuppressed
		}
		let key = method + ((object["modeId"] as? String).map { "." + $0 } ?? (object["value"] as? String).map { "." + $0 } ?? "")
		if held.contains(key) { return try await withCheckedThrowingContinuation { pending[key] = $0 } }
		if var queued = responses[method], !queued.isEmpty {
			let first = queued.removeFirst(); responses[method] = queued; return try first.get()
		}
		if method == "session/new" { return try .init(object: ["sessionId": "new", "modes": ["currentModeId": "default", "availableModes": ["default", "ask", "code"]]]) }
		return .empty
	}
	func initialize(_ advertisement: String = #"{"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{},"close":{}}}}"#) async throws {
		responses["initialize"] = [.success(try .init(data: Data(advertisement.utf8)))]
		try await session.initialize(.init(clientName: "Fixture", clientVersion: "1", clientCapabilities: .empty), rpc: rpc,
			selectAuthentication: { [weak self] methods in await self?.selectAuth(methods) },
			admit: { [weak self] _ in guard let self else { throw Failure.closed }; return try await self.admit() },
			onEvent: { events.append($0) })
	}
	func selectAuth(_ methods: [String]) -> String? { authMethods = methods; return auth }
	func admit() async throws -> OpenCodeCapabilitySnapshot.SessionCapabilities? {
		if holdAdmission { await withCheckedContinuation { admission = $0 } }
		if denyAdmission { throw Failure.admission }; return effective
	}
	func configuration(_ mode: ACPSessionLifecycle.Configuration.Mode = .new) -> ACPSessionLifecycle.Configuration {
		.init(mode: mode, workingDirectory: "/fixture", mcpServers: [.empty], providerName: "fixture")
	}
	func open(_ mode: ACPSessionLifecycle.Configuration.Mode = .new, fallback: Bool = false) async throws -> ACPSessionLifecycle.OpenResult {
		try await session.open(configuration(mode), rpc: rpc, shouldOpenFresh: { _ in fallback }, onEvent: { events.append($0) })
	}
	func waitFor(_ key: String) async throws {
		for _ in 0..<1000 { if pending[key] != nil { return }; try await Task.sleep(for: .milliseconds(1)) }
		XCTFail("No suspended request \(key)"); throw Failure.closed
	}
	func release(_ key: String, _ object: [String: Any]) throws { pending.removeValue(forKey: key)?.resume(returning: try .init(object: object)) }
}

@MainActor
final class ACPSessionLifecycleTests: XCTestCase {
	func testInitializeAuthAliasesClientIdentityAndAdmission() async throws {
		let f = Fixture(); f.auth = "login"
		try await f.initialize(#"{"authMethods":[{"id":" login "},{"methodId":" alias "},{"id":" "}],"agentCapabilities":{"loadSession":true}}"#)
		XCTAssertEqual(f.authMethods, ["login", "alias"]); XCTAssertEqual(f.calls.map(\.0), ["initialize", "authenticate"])
		let info = try f.calls[0].1.dictionary()["clientInfo"] as? [String: Any]
		XCTAssertEqual(info?["name"] as? String, "Fixture"); XCTAssertEqual(info?["version"] as? String, "1")
		XCTAssertTrue(f.session.loadSessionSupported); XCTAssertEqual(f.session.capabilitySnapshot?.authMethodIDs, [" login ", " "])
	}
	func testAdmissionCannotWidenMalformedOrAbsentAdvertisement() async throws {
		let f = Fixture(); f.effective = .init(loadSession: true, listSessions: true, resumeSession: true, closeSession: true, unstableForkSession: true)
		try await f.initialize(#"{"agentCapabilities":{"loadSession":1,"sessionCapabilities":{"list":[],"resume":"yes"}}}"#)
		XCTAssertEqual(f.session.gatingCapabilities, OpenCodeCapabilitySnapshot.SessionCapabilities.none)
		do { _ = try await f.session.list(configuration: f.configuration(), cursor: nil, rpc: f.rpc); XCTFail("Denied capability") }
		catch { XCTAssertEqual(error as? Failure, .request("ACP runtime does not advertise the 'list' session capability.")) }
	}
	func testFailedAdmissionCannotOpenSession() async throws {
		let f = Fixture(); f.denyAdmission = true
		do { try await f.initialize(); XCTFail("Admission") } catch { XCTAssertEqual(error as? Failure, .admission) }
		XCTAssertNotNil(f.session.capabilitySnapshot); XCTAssertNil(f.session.gatingCapabilities)
		do { _ = try await f.open(); XCTFail("Open before admission") } catch {}
		XCTAssertEqual(f.calls.map(\.0), ["initialize"])
	}
	func testSessionIdentityValidationAndUTF8ExactBinding() async throws {
		for id in ["", "  ", "x\n", "x\u{202e}", String(repeating: "x", count: 4097)] {
			let f = Fixture(); try await f.initialize(); f.responses["session/new"] = [.success(try .init(object: ["sessionId": id]))]
			do { _ = try await f.open(); XCTFail("Invalid ID") } catch { XCTAssertEqual(error as? Failure, .violation("session/new returned an invalid sessionId")) }
			XCTAssertNil(f.session.sessionID)
		}
		let f = Fixture(); try await f.initialize(); f.responses["session/new"] = [.success(try .init(object: ["sessionId": " raw é "]))]
		let result = try await f.open(); XCTAssertEqual(result.sessionID, " raw é ")
		XCTAssertNil(f.session.boundSessionID("raw é")); XCTAssertNotNil(f.session.boundSessionID(" raw é "))
		XCTAssertNil(f.session.boundSessionID(" raw e\u{301} "))
	}
	func testMissingNewAndInvalidPersistedIdentity() async throws {
		let f = Fixture(); try await f.initialize(); f.responses["session/new"] = [.success(.empty)]
		do { _ = try await f.open(); XCTFail("Missing ID") } catch { XCTAssertEqual(error as? Failure, .violation("session/new response missing sessionId")) }
		let g = Fixture(); try await g.initialize(); _ = try await g.open(.load("bad\n"))
		XCTAssertEqual(g.calls.map(\.0), ["initialize", "session/new"])
	}
	func testResumePreferredWithExactInFlightBindingAndNoReplay() async throws {
		let f = Fixture(); try await f.initialize(); let result = try await f.open(.load(" raw "))
		XCTAssertTrue(result.restoredExistingSession); XCTAssertEqual(f.session.sessionID, " raw ")
		XCTAssertEqual(f.binding, " raw "); XCTAssertFalse(f.replay)
		XCTAssertEqual(f.calls.map(\.0), ["initialize", "session/resume"]); XCTAssertNil(f.session.inFlightSessionID)
	}
	func testResumeLoadFreshFallbackOrderAndScope() async throws {
		let f = Fixture(); try await f.initialize()
		f.responses["session/resume"] = [.failure(.resume)]; f.responses["session/load"] = [.failure(.missing)]
		let result = try await f.open(.load(" old "), fallback: true)
		XCTAssertEqual(f.calls.map(\.0), ["initialize", "session/resume", "session/load", "session/new"])
		XCTAssertEqual(f.binding, " old "); XCTAssertTrue(f.replay)
		XCTAssertFalse(f.session.replaySuppressed); XCTAssertNil(f.session.inFlightSessionID)
		XCTAssertEqual(result.invalidatedResumeSessionID, " old "); XCTAssertEqual(f.session.invalidatedResumeSessionID, " old ")
	}
	func testLoadFailureAndUnsupportedLoadNeverCreateFreshSession() async throws {
		let f = Fixture(); try await f.initialize(#"{"agentCapabilities":{"loadSession":true}}"#); f.responses["session/load"] = [.failure(.missing)]
		do { _ = try await f.open(.load("old")); XCTFail("Load failure") } catch { XCTAssertEqual(error as? Failure, .missing) }
		XCTAssertNil(f.session.inFlightSessionID); XCTAssertFalse(f.session.replaySuppressed)
		XCTAssertFalse(f.calls.contains { $0.0 == "session/new" })
		let g = Fixture(); try await g.initialize("{}")
		do { _ = try await g.open(.load("old")); XCTFail("Unsupported load") }
		catch { XCTAssertEqual(error as? Failure, .request("ACP runtime does not support session/load for existing session old.")) }
		XCTAssertEqual(g.calls.map(\.0), ["initialize"])
	}
	func testListCursorRawDescriptorsAndCloseWire() async throws {
		let f = Fixture(); try await f.initialize(); _ = try await f.open()
		f.responses["session/list"] = [.success(try .init(object: ["sessions": [["sessionId": " raw ", "future": [1,2]]], "nextCursor": " cursor "]))]
		let result = try await f.session.list(configuration: f.configuration(), cursor: " input ", rpc: f.rpc)
		XCTAssertEqual(result.nextCursor, " cursor "); XCTAssertEqual(try result.sessions[0].dictionary()["sessionId"] as? String, " raw ")
		XCTAssertEqual(try f.calls.last?.1.dictionary()["cursor"] as? String, " input ")
		try await f.session.close(rpc: f.rpc); XCTAssertEqual(f.calls.last?.0, "session/close"); XCTAssertEqual(f.session.sessionID, "new")
	}
	func testModeDiscoveryValidationAndDefaultNoOp() async throws {
		let f = Fixture(); try await f.initialize(); _ = try await f.open()
		try await f.session.setMode(" ASK ", rpc: f.rpc); XCTAssertEqual(f.session.currentModeID, "ASK"); let count = f.calls.count
		try await f.session.setMode("ask", rpc: f.rpc); XCTAssertEqual(f.calls.count, count)
		do { try await f.session.setMode("unknown", rpc: f.rpc); XCTFail("Unknown mode") }
		catch { XCTAssertEqual(error as? Failure, .request("ACP runtime does not advertise session mode 'unknown'. Available modes: ask, code, default.")) }
		let g = Fixture(); try await g.initialize(); g.responses["session/new"] = [.success(try .init(object: ["sessionId": "new"]))]; _ = try await g.open()
		try await g.session.setMode("default", rpc: g.rpc); XCTAssertEqual(g.calls.count, 2)
	}
	func testRetirementDuringInitializePreventsAuthAndAdmission() async throws {
		let f = Fixture(); f.held.insert("initialize")
		let task = Task { try await f.initialize() }; try await f.waitFor("initialize")
		f.session.invalidate(); try f.release("initialize", ["authMethods": [["id": "login"]]])
		do { try await task.value; XCTFail("Retired") } catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertNil(f.session.capabilitySnapshot); XCTAssertEqual(f.calls.count, 1)
	}
	func testRetirementDuringAdmissionCannotOpen() async throws {
		let f = Fixture(); f.holdAdmission = true; let task = Task { try await f.initialize() }
		for _ in 0..<1000 { if f.admission != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
		XCTAssertNotNil(f.admission); f.session.invalidate(); f.admission?.resume(); f.admission = nil
		do { try await task.value; XCTFail("Retired admission") } catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertNil(f.session.gatingCapabilities); XCTAssertNil(f.session.sessionID)
	}
	func testRetirementDuringLoadCannotFallbackOrCommit() async throws {
		let f = Fixture(); try await f.initialize(#"{"agentCapabilities":{"loadSession":true}}"#); f.held.insert("session/load")
		let task = Task { try await f.open(.load("old"), fallback: true) }; try await f.waitFor("session/load")
		f.session.invalidate(); try f.release("session/load", [:])
		do { _ = try await task.value; XCTFail("Retired load") } catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertNil(f.session.sessionID); XCTAssertFalse(f.session.replaySuppressed); XCTAssertFalse(f.calls.contains { $0.0 == "session/new" })
	}
	func testRetirementDuringNewAndConcurrentOpenGuard() async throws {
		let f = Fixture(); try await f.initialize(); f.held.insert("session/new")
		let task = Task { try await f.open() }; try await f.waitFor("session/new")
		do { _ = try await f.open(); XCTFail("Concurrent open") } catch { XCTAssertTrue(error is ACPSessionLifecycle.OperationError) }
		f.session.invalidate(); try f.release("session/new", ["sessionId": "late"])
		do { _ = try await task.value; XCTFail("Retired new") } catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertNil(f.session.sessionID)
	}
	func testRetiredModeCannotCommitAndRecoveryIdentityRemains() async throws {
		let f = Fixture(); try await f.initialize(); _ = try await f.open(); f.held.insert("session/set_mode.ask")
		let task = Task { try await f.session.setMode("ask", rpc: f.rpc) }; try await f.waitFor("session/set_mode.ask")
		f.session.invalidate(); try f.release("session/set_mode.ask", [:])
		do { try await task.value; XCTFail("Retired mode") } catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertEqual(f.session.currentModeID, "default"); XCTAssertEqual(f.session.sessionID, "new")
		f.session.clearConfigurationAfterShutdown(); XCTAssertNil(f.session.currentModeID); XCTAssertNotNil(f.session.capabilitySnapshot)
	}
	func testReentrantRetirementBeforeInitializeWritePreventsRPC() async throws {
		let f = Fixture()
		do {
			try await f.session.initialize(.init(clientName: "host", clientVersion: "1", clientCapabilities: .empty),
				rpc: f.rpc, selectAuthentication: { _ in nil }, admit: { _ in nil }, onEvent: { event in
					if case .phaseStarted("initialize") = event { f.session.invalidate() }
				})
			XCTFail("Retired before write")
		} catch { XCTAssertEqual(error as? Failure, .closed) }
		XCTAssertTrue(f.calls.isEmpty)
	}
	func testNativeActorOwnsLifecycleAndSynchronousObservation() async throws {
		let owner = SessionOwner()
		let id = try await owner.exercise()
		XCTAssertEqual(id, " actor ")
		let count = await owner.initializedEvents
		XCTAssertEqual(count, 1)
	}

	func testLatestNoOpModeChoiceSupersedesPendingChange() async throws {
		let f = Fixture(); try await f.initialize(); _ = try await f.open(); f.held.insert("session/set_mode.ask")
		let old = Task { try await f.session.setMode("ask", rpc: f.rpc) }; try await f.waitFor("session/set_mode.ask")
		try await f.session.setMode("default", rpc: f.rpc)
		try f.release("session/set_mode.ask", [:]); try await old.value
		XCTAssertEqual(f.session.currentModeID, "default")
	}

	func testReorderedModeAndModelRepliesCannotOverwriteLatestSelection() async throws {
		let f = Fixture(); try await f.initialize(); _ = try await f.open()
		f.held = ["session/set_mode.ask", "session/set_mode.code", "session/set_config_option.one", "session/set_config_option.two"]
		let a = Task { try await f.session.setMode("ask", rpc: f.rpc) }; try await f.waitFor("session/set_mode.ask")
		let b = Task { try await f.session.setMode("code", rpc: f.rpc) }; try await f.waitFor("session/set_mode.code")
		try f.release("session/set_mode.code", [:]); try await b.value; try f.release("session/set_mode.ask", [:]); try await a.value
		XCTAssertEqual(f.session.currentModeID, "code")
		let c = Task { try await f.session.setModelConfiguration("one", rpc: f.rpc, onEvent: { f.events.append($0) }) }; try await f.waitFor("session/set_config_option.one")
		let d = Task { try await f.session.setModelConfiguration("two", rpc: f.rpc, onEvent: { f.events.append($0) }) }; try await f.waitFor("session/set_config_option.two")
		try f.release("session/set_config_option.two", ["models": ["currentModelId": "two"]]); try await d.value
		try f.release("session/set_config_option.one", ["models": ["currentModelId": "one"]]); try await c.value
		XCTAssertEqual(f.session.models?.currentModelRaw, "two"); XCTAssertEqual(f.session.currentModeID, "code")
	}
}

private actor SessionOwner {
	private let session = ACPSessionLifecycle(errors: .init(closed: { Failure.closed }, requestFailed: { Failure.request($0) }, protocolViolation: { Failure.violation($0) }))
	private(set) var initializedEvents = 0
	func exercise() async throws -> String {
		let rpc: ACPSessionLifecycle.RPC = { method, _ in
			if method == "initialize" { return .empty }
			return try .init(object: ["sessionId": " actor "])
		}
		try await session.initialize(.init(clientName: "actor", clientVersion: "1", clientCapabilities: .empty),
			rpc: rpc, selectAuthentication: { _ in nil }, admit: { _ in nil }, onEvent: {
				if case .initialized = $0 { initializedEvents += 1 }
			})
		return try await session.open(.init(mode: .new, workingDirectory: "/fixture", mcpServers: [], providerName: "actor"),
			rpc: rpc, shouldOpenFresh: { _ in false }, onEvent: { _ in }).sessionID
	}
}
