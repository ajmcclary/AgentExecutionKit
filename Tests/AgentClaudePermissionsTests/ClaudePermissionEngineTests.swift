import XCTest
import Foundation
import AgentClaudeProtocol
import AgentRuntimeKit
import AgentClaudePermissions

final class ClaudePermissionEngineTests: XCTestCase {
	enum Failure: Error { case write }
	private func request(_ id: String = "p", subtype: String = "can_use_tool", input: [String: Any] = ["command": "echo hi"]) throws -> ClaudeNativeProtocolCodec.ControlRequest {
		.init(requestID: id, request: try .init(object: ["tool_name": "Bash", "input": input]), subtype: subtype)
	}
	private func approval(_ request: ClaudeNativeProtocolCodec.ControlRequest) -> AgentApprovalRequest {
		.init(requestID: .claudeControl(request.requestID), method: "control/can_use_tool", kind: .commandExecution,
			threadID: "session", turnID: "turn", itemID: request.requestID)
	}
	private func register(_ engine: ClaudePermissionEngine, _ id: String = "p") throws -> ClaudePermissionEngine.Ticket {
		var ticket: ClaudePermissionEngine.Ticket?
		try engine.receive(request(id), policy: { .present(self.approval($0)) }, write: { _ in XCTFail("Manual request") },
			observe: { if case .requested(_, let value) = $0 { ticket = value } })
		return try XCTUnwrap(ticket)
	}
	private func wire(_ data: Data) throws -> [String: Any] {
		let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(value["type"] as? String, "control_response")
		return try XCTUnwrap(value["response"] as? [String: Any])
	}

	private func assertFalseWithoutThrow(_ action: () throws -> Bool) {
		do { let value = try action(); XCTAssertFalse(value) } catch { XCTFail("Unexpected error: \(error)") }
	}
	func testAllowPayloadPreservesToolUseIDAndUpdatedInput() throws {
		let object = try ClaudeProtocolJSONObject(object: ["tool_use_id": "toolu_123", "input": ["command": "echo hi", "description": "demo"]])
		let payload = try ClaudePermissionEngine.allowResponse(object, includeUpdatedPermissions: false).dictionary()
		XCTAssertEqual(payload["behavior"] as? String, "allow")
		let input = payload["updatedInput"] as? [String: Any]
		XCTAssertEqual(input?["command"] as? String, "echo hi"); XCTAssertEqual(input?["description"] as? String, "demo")
		XCTAssertEqual(payload["toolUseID"] as? String, "toolu_123"); XCTAssertNil(payload["updatedPermissions"])
	}
	func testSessionAcceptIncludesSuggestionsExactlyAsAdvertised() throws {
		let object = try ClaudeProtocolJSONObject(object: ["tool_use_id": "toolu_456", "input": ["path": "README.md"],
			"permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session", "future": 9]]])
		for decision in [AgentApprovalDecision.acceptForSession, .acceptWithExecpolicyAmendment("ignored legacy amendment")] {
			let payload = try ClaudePermissionEngine.response(decision, request: object).dictionary()
			let suggestions = try XCTUnwrap(payload["updatedPermissions"] as? [[String: Any]])
			XCTAssertEqual(suggestions.count, 1); XCTAssertEqual(suggestions.first?["type"] as? String, "setMode")
			XCTAssertEqual(suggestions.first?["future"] as? Int, 9)
		}
		XCTAssertNil(try ClaudePermissionEngine.response(.accept, request: object).dictionary()["updatedPermissions"])
	}
	func testDeclineAndCancelKeepExactWireWordingAndInterruptDifference() throws {
		let object = try ClaudeProtocolJSONObject(object: [:])
		let decline = try ClaudePermissionEngine.response(.decline, request: object).dictionary()
		XCTAssertEqual(decline["behavior"] as? String, "deny"); XCTAssertEqual(decline["message"] as? String, "Permission denied by user.")
		XCTAssertNil(decline["interrupt"])
		let cancel = try ClaudePermissionEngine.response(.cancel, request: object).dictionary()
		XCTAssertEqual(cancel["message"] as? String, "Permission cancelled by user."); XCTAssertEqual(cancel["interrupt"] as? Bool, true)
	}
	func testMissingOrMalformedInputAndSuggestionsKeepLegacyDefaults() throws {
		for suggestions: Any in [[], "wrong", [["type": "setMode"], "mixed"]] {
			let object = try ClaudeProtocolJSONObject(object: ["input": "wrong", "permission_suggestions": suggestions, "tool_use_id": " \n"])
			let payload = try ClaudePermissionEngine.allowResponse(object, includeUpdatedPermissions: true).dictionary()
			XCTAssertTrue((payload["updatedInput"] as? [String: Any])?.isEmpty == true)
			XCTAssertNil(payload["updatedPermissions"]); XCTAssertNil(payload["toolUseID"])
		}
	}
	func testLargeIntegersAndUnknownInputSurviveEncoding() throws {
		let object = try ClaudeProtocolJSONObject(data: Data(#"{"tool_use_id":" raw ","input":{"large":9007199254740993,"future":[true,null]}}"#.utf8))
		let payload = try ClaudePermissionEngine.allowResponse(object, includeUpdatedPermissions: false).dictionary()
		XCTAssertEqual(payload["toolUseID"] as? String, "raw")
		let input = try XCTUnwrap(payload["updatedInput"] as? [String: Any])
		XCTAssertEqual((input["large"] as? NSNumber)?.stringValue, "9007199254740993")
		XCTAssertEqual((input["future"] as? [Any])?.count, 2)
	}
	func testManualPresentationRegistersBeforeCallbackAndRepliesOnlyOnDecision() throws {
		let engine = ClaudePermissionEngine(); let value = try request(); var ticket: ClaudePermissionEngine.Ticket?
		XCTAssertTrue(try engine.receive(value, policy: { .present(self.approval($0)) }, write: { _ in XCTFail("Manual") }, observe: {
			guard case .requested(let approval, let token) = $0 else { return XCTFail("Expected presentation") }
			XCTAssertEqual(approval.requestID, .claudeControl("p")); XCTAssertEqual(engine.ticket(for: "p"), token); ticket = token
		}))
		var order: [String] = []
		XCTAssertTrue(try engine.respond(XCTUnwrap(ticket), decision: .accept, write: { bytes in
			order.append("write"); let payload = try wire(bytes)
			XCTAssertEqual(payload["request_id"] as? String, "p"); XCTAssertEqual(payload["subtype"] as? String, "success")
		}, observe: { _ in order.append("observe"); XCTAssertNil(engine.ticket(for: "p")) }))
		XCTAssertEqual(order, ["observe", "write"]); XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
	}
	func testAutomaticPolicyWritesAllowOnceWithoutPresentationOrStoredPending() throws {
		let engine = ClaudePermissionEngine(); var writes = 0
		XCTAssertTrue(try engine.receive(request(), policy: { _ in .allowOnce }, write: { bytes in
			writes += 1; let result = try XCTUnwrap(wire(bytes)["response"] as? [String: Any])
			XCTAssertEqual(result["behavior"] as? String, "allow"); XCTAssertNil(result["updatedPermissions"])
		}, observe: { guard case .willReply(_, .automatic, _) = $0 else { return XCTFail("Automatic") } }))
		XCTAssertEqual(writes, 1); XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
	}
	func testUnsupportedSubtypeKeepsErrorAndDoesNotInvokeAuthorizationPolicy() throws {
		let engine = ClaudePermissionEngine()
		try engine.receive(request(subtype: "future"), policy: { _ in XCTFail("Unsupported"); return .allowOnce }, write: { bytes in
			let result = try wire(bytes); XCTAssertEqual(result["subtype"] as? String, "error")
			XCTAssertEqual(result["error"] as? String, "Unsupported control request subtype: future")
		}, observe: { _ in })
	}
	func testRepeatedDecisionCannotReplyTwice() throws {
		let engine = ClaudePermissionEngine(); let ticket = try register(engine); var writes = 0
		for _ in 0..<3 { _ = try engine.respond(ticket, decision: .decline, write: { _ in writes += 1 }, observe: { _ in }) }
		XCTAssertEqual(writes, 1)
	}
	func testCancellationRemovesOnlyPendingIdentityAndWritesNothing() throws {
		let engine = ClaudePermissionEngine(); let first = try register(engine, "a"); _ = try register(engine, "b")
		XCTAssertTrue(engine.cancel(first)); XCTAssertFalse(engine.cancel(first))
		XCTAssertEqual(engine.pendingRequestIDs, ["b"])
		XCTAssertFalse(try engine.respond(first, decision: .accept, write: { _ in XCTFail("Cancelled") }, observe: { _ in XCTFail("Cancelled") }))
	}
	func testScopeRetirementRejectsOldTicketsAndLateRequestsUntilReopened() throws {
		let engine = ClaudePermissionEngine(); let old = try register(engine); engine.retire()
		XCTAssertFalse(try engine.receive(request(), policy: { _ in XCTFail("Retired"); return .allowOnce }, write: { _ in XCTFail("Retired") }, observe: { _ in XCTFail("Retired") }))
		engine.beginScope(); let new = try register(engine)
		XCTAssertNotEqual(old, new); XCTAssertFalse(engine.cancel(old))
		XCTAssertFalse(try engine.respond(old, decision: .accept, write: { _ in XCTFail("Old") }, observe: { _ in XCTFail("Old") }))
		XCTAssertEqual(engine.ticket(for: "p"), new)
	}
	func testIDReuseAfterCancellationStillExpiresOldTicketWithinSameScope() throws {
		let engine = ClaudePermissionEngine(); let old = try register(engine); XCTAssertTrue(engine.cancel(old)); let new = try register(engine)
		XCTAssertNotEqual(old, new); XCTAssertFalse(engine.cancel(old)); XCTAssertEqual(engine.ticket(for: "p"), new)
	}
	func testDuplicateIncludingUnsupportedPayloadDoesNotReplaceOutstandingRequest() throws {
		let engine = ClaudePermissionEngine(); let original = try register(engine)
		XCTAssertFalse(try engine.receive(request(subtype: "unknown"), policy: { _ in XCTFail("Duplicate"); return .allowOnce }, write: { _ in XCTFail("Duplicate") }, observe: { _ in XCTFail("Duplicate") }))
		XCTAssertEqual(engine.ticket(for: "p"), original)
	}
	func testUTF8IdentityDoesNotCollapseCanonicallyEquivalentWireIDs() throws {
		let engine = ClaudePermissionEngine(); let first = try register(engine, "é"); let second = try register(engine, "e\u{301}")
		XCTAssertNotEqual(first, second); XCTAssertEqual(engine.pendingRequestIDs.count, 2)
		XCTAssertTrue(engine.cancel(first)); XCTAssertEqual(engine.ticket(for: second.requestID), second)
	}
	func testDuplicateDuringPolicyAndAutomaticWriteIsReserved() throws {
		let engine = ClaudePermissionEngine(); let value = try request(); var writes = 0
		let duplicate = { self.assertFalseWithoutThrow { try engine.receive(value, policy: { _ in XCTFail("Duplicate"); return .allowOnce }, write: { _ in XCTFail("Duplicate") }, observe: { _ in XCTFail("Duplicate") }) } }
		try engine.receive(value, policy: { _ in duplicate(); return .allowOnce }, write: { _ in duplicate(); writes += 1 }, observe: { _ in duplicate() })
		XCTAssertEqual(writes, 1)
	}
	func testPolicyRetirementCannotPresentOrWriteInNewScope() throws {
		let engine = ClaudePermissionEngine()
		XCTAssertFalse(try engine.receive(request(), policy: { value in engine.beginScope(); return .present(self.approval(value)) },
			write: { _ in XCTFail("Retired") }, observe: { _ in XCTFail("Retired") }))
		XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
	}
	func testObservationRetirementPreventsWireWriteAndDoesNotDeleteReplacement() throws {
		let engine = ClaudePermissionEngine(); let old = try register(engine); var new: ClaudePermissionEngine.Ticket?
		XCTAssertFalse(try engine.respond(old, decision: .accept, write: { _ in XCTFail("Retired") }, observe: { _ in
			engine.beginScope(); new = try? register(engine)
		}))
		XCTAssertEqual(engine.ticket(for: "p"), new)
	}
	func testReentrantDecisionAndCancellationCannotCreateSecondReply() throws {
		let engine = ClaudePermissionEngine(); let ticket = try register(engine); var writes = 0
		try engine.respond(ticket, decision: .accept, write: { _ in writes += 1 }, observe: { _ in
			XCTAssertFalse(engine.cancel(ticket))
			assertFalseWithoutThrow { try engine.respond(ticket, decision: .decline, write: { _ in XCTFail("Second reply") }, observe: { _ in XCTFail("Second reply") }) }
		})
		XCTAssertEqual(writes, 1)
	}
	func testWriteFailureRetiresDecisionAndPropagatesOriginalError() throws {
		let engine = ClaudePermissionEngine(); let ticket = try register(engine)
		XCTAssertThrowsError(try engine.respond(ticket, decision: .accept, write: { _ in throw Failure.write }, observe: { _ in }))
		XCTAssertNil(engine.ticket(for: "p")); XCTAssertFalse(engine.cancel(ticket))
	}
	func testAutomaticWriteFailureCleansReservationAndCanAcceptNewRequest() throws {
		let engine = ClaudePermissionEngine()
		XCTAssertThrowsError(try engine.receive(request(), policy: { _ in .allowOnce }, write: { _ in throw Failure.write }, observe: { _ in }))
		_ = try register(engine); XCTAssertEqual(engine.pendingRequestIDs, ["p"])
	}
	func testRetirementDuringWriteSuppressesStaleFailure() throws {
		let engine = ClaudePermissionEngine(); let ticket = try register(engine)
		XCTAssertFalse(try engine.respond(ticket, decision: .accept, write: { _ in engine.beginScope(); throw Failure.write }, observe: { _ in }))
		XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
	}
}
