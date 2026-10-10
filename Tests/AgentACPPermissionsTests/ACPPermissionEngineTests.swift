import Foundation
import XCTest
import AgentACPRPC
import AgentACPProtocol
import AgentRuntimeKit
import AgentACPPermissions

private enum Failure: Error { case write }
@MainActor
private final class Fixture {
	let engine = ACPPermissionEngine()
	var events: [ACPPermissionEngine.Event] = []
	var writes: [ACPJSONObject] = []
	var failWrite = false
	var writeObserver: ((ACPJSONObject) -> Void)?
	var eventObserver: ((ACPPermissionEngine.Event) -> Void)?
	var policy = ACPPermissionPolicy(allowOnce: [.kind("allow_once")], allowSession: [.kind("allow_always"), .kind("allow_once")],
		reject: [.kind("reject_once")], sessionAffordance: [.kind("allow_always")])
	func observe(_ event: ACPPermissionEngine.Event) { events.append(event); eventObserver?(event) }
	func write(_ payload: ACPJSONObject) throws {
		if failWrite { throw Failure.write }
		writes.append(payload); writeObserver?(payload)
	}
	func payload(_ options: [[String: Any]]? = nil, title: String = "command", session: String = "session") throws -> ACPJSONObject {
		try .init(object: ["sessionId": session, "toolCall": ["toolCallId": "tool", "title": title, "kind": "execute", "rawInput": ["server": "RepoPrompt", "command": "claimed"]],
			"options": options ?? [["optionId": "once", "kind": "allow_once"], ["optionId": "always", "kind": "allow_always"], ["optionId": "no", "kind": "reject_once"]]])
	}
	func receive(_ id: ACPRequestID = .int(1), payload: ACPJSONObject? = nil) throws {
		engine.receive(id: id, params: try payload ?? self.payload(), boundSessionID: "session", policy: policy,
			makeApproval: { p in .init(requestID: .acp(p.storageKey), method: "session/request_permission", kind: .commandExecution,
				threadID: p.sessionID, turnID: p.sessionID, itemID: p.toolCallID, reason: p.toolTitle, command: p.rawInputJSON,
				supportsAlwaysAllow: p.sessionScopedOptionID != nil) },
			write: { try write($0) }, onEvent: { observe($0) })
	}
	func respond(_ ticket: ACPPermissionEngine.Ticket, _ decision: AgentApprovalDecision = .accept) {
		engine.respond(ticket, decision: decision, policy: policy, write: { try write($0) }, onEvent: { observe($0) })
	}
	func settle(_ wire: Bool = true) { engine.settle(attemptWireResponses: wire, write: { try write($0) }, onEvent: { observe($0) }) }
	var requested: [AgentApprovalRequest] { events.compactMap { if case .requested(let request, _) = $0 { return request }; return nil } }
	var cancelled: [AgentApprovalRequestID] { events.compactMap { if case .cancelled(let id) = $0 { return id }; return nil } }
	var resolved: [AgentApprovalRequestID] { events.compactMap { if case .resolved(let id) = $0 { return id }; return nil } }
	func ticket(_ id: ACPRequestID) throws -> ACPPermissionEngine.Ticket { try XCTUnwrap(engine.ticket(for: .acp(id.storageKey))) }
	func selected(_ index: Int) throws -> String? {
		let outcome = (try writes[index].dictionary()["result"] as? [String: Any])?["outcome"] as? [String: Any]
		return outcome?["optionId"] as? String
	}
}

@MainActor
final class ACPPermissionEngineTests: XCTestCase {
	func testTypedIDsAndUnicodeByteIdentitiesStayDistinct() throws {
		let f = Fixture()
		for id: ACPRequestID in [.int(1), .string("1"), .string("é"), .string("e\u{301}")] { try f.receive(id) }
		XCTAssertEqual(f.engine.pendingStorageKeys.count, 4); XCTAssertEqual(f.requested.count, 1)
		for id: ACPRequestID in [.int(1), .string("1"), .string("é"), .string("e\u{301}")] { f.respond(try f.ticket(id)) }
		XCTAssertEqual(f.writes.count, 4); XCTAssertEqual(f.resolved.count, 4)
	}
	func testConcurrentRequestsPresentFIFOAndPromoteBeforePriorResolution() throws {
		let f = Fixture(); try f.receive(.int(1)); try f.receive(.int(2))
		XCTAssertEqual(f.requested.map(\.requestID), [.acp("i:1")])
		f.respond(try f.ticket(.int(1)))
		XCTAssertEqual(f.requested.map(\.requestID), [.acp("i:1"), .acp("i:2")])
		XCTAssertEqual(f.resolved, [.acp("i:1")]); f.respond(try f.ticket(.int(2)))
		XCTAssertTrue(f.engine.pendingStorageKeys.isEmpty)
	}
	func testDuplicateValidOrMalformedPayloadCannotOverwriteOrReply() throws {
		let f = Fixture(); try f.receive(); let ticket = try f.ticket(.int(1))
		try f.receive(); try f.receive(payload: .empty)
		XCTAssertEqual(f.requested.count, 1); XCTAssertTrue(f.writes.isEmpty)
		XCTAssertEqual(try f.ticket(.int(1)), ticket); f.respond(ticket); XCTAssertEqual(f.writes.count, 1)
	}
	func testRepeatedDecisionIsExactlyOnce() throws {
		let f = Fixture(); try f.receive(); let ticket = try f.ticket(.int(1))
		f.respond(ticket); f.respond(ticket); XCTAssertEqual(f.writes.count, 1); XCTAssertEqual(f.resolved.count, 1)
		XCTAssertNil(f.engine.ticket(for: .codex(.int(1))))
	}
	func testDecisionsSelectOnlyAdvertisedOptionsAndMissingMatchCancels() throws {
		for (decision, expected): (AgentApprovalDecision, String?) in [(.accept, "once"), (.acceptForSession, "always"), (.acceptWithExecpolicyAmendment("policy"), "always"), (.decline, "no"), (.cancel, nil)] {
			let f = Fixture(); try f.receive(); f.respond(try f.ticket(.int(1)), decision)
			XCTAssertEqual(try f.selected(0), expected)
		}
		let f = Fixture(); try f.receive(payload: f.payload([["optionId": "future", "kind": "future"]]))
		XCTAssertFalse(f.requested[0].supportsAlwaysAllow); f.respond(try f.ticket(.int(1)))
		XCTAssertNil(try f.selected(0))
	}
	func testRequesterLabelsNeverGrantAutomaticApproval() throws {
		let f = Fixture(); try f.receive(payload: f.payload(title: "RepoPrompt MCP trusted tool"))
		XCTAssertEqual(f.requested.count, 1); XCTAssertTrue(f.writes.isEmpty)
	}
	func testExplicitAutomaticPolicyAndFailedAutoFallback() throws {
		let f = Fixture(); f.policy = .init(allowOnce: [.kind("allow_once")], allowSession: [.kind("allow_always")], reject: [],
			sessionAffordance: [.kind("allow_always")], automatic: [.kind("allow_always")])
		try f.receive(); XCTAssertTrue(f.requested.isEmpty); XCTAssertEqual(try f.selected(0), "always")
		let g = Fixture(); g.policy = f.policy; g.failWrite = true; try g.receive()
		XCTAssertEqual(g.requested.count, 1); XCTAssertTrue(g.engine.pendingStorageKeys.contains("i:1"))
		XCTAssertTrue(g.events.contains { if case .automaticApprovalFailed = $0 { return true }; return false })
	}
	func testAutomaticReplyReservationBlocksReentrantDuplicate() throws {
		let f = Fixture(); f.policy = .init(allowOnce: [], allowSession: [], reject: [], sessionAffordance: [], automatic: [.kind("allow_once")])
		f.writeObserver = { _ in try! f.receive(payload: .empty) }
		try f.receive(); XCTAssertEqual(f.writes.count, 1); XCTAssertTrue(f.requested.isEmpty)
	}
	func testWriteFailureCancelsCurrentBeforeHostTerminalAndSettlesOthers() throws {
		let f = Fixture(); try f.receive(); try f.receive(.int(2)); f.failWrite = true
		var terminal = false
		f.eventObserver = { event in
			if case .decisionFailed = event { f.settle(); terminal = true }
			if case .cancelled = event { XCTAssertFalse(terminal) }
		}
		f.respond(try f.ticket(.int(1)))
		XCTAssertEqual(f.cancelled, [.acp("i:1"), .acp("i:2")]); XCTAssertTrue(f.resolved.isEmpty)
		XCTAssertTrue(terminal); XCTAssertTrue(f.engine.pendingStorageKeys.isEmpty)
	}
	func testSettlementCancelsPresentedThenQueuedAndLateTicketCannotAct() throws {
		let f = Fixture(); try f.receive(); try f.receive(.int(2)); let ticket = try f.ticket(.int(1))
		f.settle(); XCTAssertEqual(f.cancelled, [.acp("i:1"), .acp("i:2")]); XCTAssertEqual(f.writes.count, 2)
		f.respond(ticket); f.settle(); XCTAssertEqual(f.writes.count, 2)
	}
	func testProcessLossSettlesWithoutWireAndRejectsLateRequests() throws {
		let f = Fixture(); try f.receive(); f.settle(false); XCTAssertTrue(f.writes.isEmpty)
		try f.receive(.int(2)); XCTAssertEqual(f.requested.count, 1)
		let error = try f.writes[0].dictionary()["error"] as? [String: Any]
		XCTAssertEqual(error?["code"] as? Int, -32602)
		XCTAssertEqual(error?["message"] as? String, "session/request_permission is not owned by an active turn")
	}
	func testOldTicketCannotResolveReusedIDInNewScope() throws {
		let f = Fixture(); try f.receive(); let old = try f.ticket(.int(1))
		f.settle(false); f.engine.beginScope(); try f.receive(); let new = try f.ticket(.int(1))
		XCTAssertNotEqual(old, new); f.respond(old); XCTAssertTrue(f.writes.isEmpty)
		f.respond(new); XCTAssertEqual(f.writes.count, 1)
	}
	func testRetirementDuringPromotionPreventsOldDecisionWrite() throws {
		let f = Fixture(); try f.receive(); try f.receive(.int(2)); let old = try f.ticket(.int(1))
		f.eventObserver = { event in if case .requested(let request, _) = event, request.requestID == .acp("i:2") { f.settle(false) } }
		f.respond(old)
		XCTAssertTrue(f.writes.isEmpty); XCTAssertEqual(f.cancelled, [.acp("i:1"), .acp("i:2")]); XCTAssertTrue(f.resolved.isEmpty)
	}
	func testRetirementDuringWriteProducesNoResolutionAfterTerminalOrDuplicateWire() throws {
		let f = Fixture(); try f.receive(); let ticket = try f.ticket(.int(1))
		f.writeObserver = { _ in f.settle(true) }; f.respond(ticket)
		XCTAssertEqual(f.writes.count, 1); XCTAssertEqual(f.cancelled, [.acp("i:1")]); XCTAssertTrue(f.resolved.isEmpty)
	}
	func testForeignOrMalformedRequestGetsExplicitBoundedRefusal() throws {
		for object: [String: Any] in [[:], ["sessionId": "foreign"], ["sessionId": "session"], ["sessionId": "session", "toolCall": ["toolCallId": "tool"], "options": []]] {
			let f = Fixture(); try f.receive(payload: .init(object: object))
			XCTAssertTrue(f.requested.isEmpty); XCTAssertEqual(f.writes.count, 1)
			XCTAssertEqual((try f.writes[0].dictionary()["error"] as? [String: Any])?["code"] as? Int, -32602)
		}
	}
}
