import Foundation
import XCTest
import AgentClaudePermissions
import AgentClaudeProtocol
import AgentRuntimeKit

final class ClaudePermissionPresentationTests: XCTestCase {
    private let context = ClaudePermissionPresentation.Context(threadID: "thread-A", turnID: "turn-A", workspacePath: "/host/root")
    private func request(_ payload: [String: Any], id: String = "raw-request") throws -> ClaudeNativeProtocolCodec.ControlRequest {
        .init(requestID: id, request: try .init(object: payload), subtype: "can_use_tool")
    }
    func testSanitizedApprovalPreservesLegacyStableIDsAndCompleteDetailOrder() throws {
        let approval = ClaudePermissionPresentation.make(from: try request(["tool_name": " Bash ", "tool_use_id": " tool-1 ", "input": ["command": " printf fixture "], "blocked_path": "/host/file", "decision_reason": "requested change", "description": "run command"]), context: context)
        XCTAssertEqual(approval.id.uuidString, "C22C7EB2-D147-227D-9335-2ABF84914AF7")
        XCTAssertEqual(approval.details.map { $0.id.uuidString }, ["0D9856F7-FA60-70AF-2C6F-110D038B22FA", "BC0AD3DD-6193-B3A1-8548-81AA38780951", "D5F1B45D-0FE4-9087-5CFC-A24F35FA0E0B", "85D3D16D-DDEA-6B20-2426-58D9B7F5B3ED", "85C0F3D8-8B5A-FC32-FBF4-6DB289F7AE0A"])
        XCTAssertEqual(approval.details.map { $0.label }, ["Tool", "Command", "Blocked Path", "Reason", "Description"])
        XCTAssertEqual(approval.details.map { $0.value }, ["Bash", "printf fixture", "/host/file", "requested change", "run command"])
        XCTAssertEqual(approval.details.map { $0.isCode }, [true, true, true, false, false])
        XCTAssertEqual(approval.requestID, .claudeControl("raw-request")); XCTAssertEqual(approval.method, "control/can_use_tool")
        XCTAssertEqual(approval.kind, .commandExecution); XCTAssertEqual(approval.threadID, "thread-A"); XCTAssertEqual(approval.turnID, "turn-A")
        XCTAssertEqual(approval.itemID, "tool-1"); XCTAssertEqual(approval.reason, "requested change")
        XCTAssertEqual(approval.command, "printf fixture"); XCTAssertEqual(approval.cwd, "/host/root"); XCTAssertEqual(approval.grantRoot, "/host/file")
    }
    func testUnknownToolsUseGenericFileApprovalWithoutInventingFields() throws {
        let approval = ClaudePermissionPresentation.make(from: try request(["tool_name": "FutureTool", "future": true]), context: context)
        XCTAssertEqual(approval.kind, .fileChange); XCTAssertEqual(approval.itemID, "raw-request")
        XCTAssertEqual(approval.details.map { $0.label }, ["Tool"])
        XCTAssertNil(approval.command); XCTAssertNil(approval.reason); XCTAssertNil(approval.grantRoot)
    }
    func testMissingMalformedAndEmptyToolValuesRetainLegacyFallbackSemantics() throws {
        for value in [[:], ["tool_name": 3], ["tool_name": " "]] as [[String: Any]] {
            let approval = ClaudePermissionPresentation.make(from: try request(value), context: context)
            XCTAssertEqual(approval.kind, .fileChange)
            XCTAssertEqual(approval.details.first?.value, value["tool_name"] is String ? "" : "tool")
        }
    }
    func testEmptyToolUseIDFallsBackToRawRequestIDAndWhitespaceDetailsArePreserved() throws {
        let approval = ClaudePermissionPresentation.make(from: try request(["tool_name": "Shell", "tool_use_id": " ", "input": ["command": " "], "blocked_path": " ", "decision_reason": " ", "description": " "]), context: context)
        XCTAssertEqual(approval.itemID, "raw-request"); XCTAssertEqual(approval.command, "")
        XCTAssertEqual(approval.details.map { $0.label }, ["Tool", "Blocked Path", "Reason", "Description"])
        XCTAssertEqual(approval.grantRoot, " "); XCTAssertEqual(approval.reason, " ")
    }
    func testMalformedInputAndAbsentWorkspaceDoNotInventACommandOrRoot() throws {
        let approval = ClaudePermissionPresentation.make(from: try request(["tool_name": "Bash", "input": [1, 2], "blocked_path": 3]), context: .init(threadID: "t", turnID: "r", workspacePath: nil))
        XCTAssertNil(approval.command); XCTAssertNil(approval.cwd); XCTAssertNil(approval.grantRoot)
        XCTAssertEqual(approval.kind, .commandExecution); XCTAssertEqual(approval.details.count, 1)
    }
    func testHostContextsKeepIdentitiesIsolatedAndRepeatedProjectionIsStable() throws {
        let value = try request(["tool_name": "Bash"])
        let a = ClaudePermissionPresentation.make(from: value, context: context)
        XCTAssertEqual(a, ClaudePermissionPresentation.make(from: value, context: context))
        for next in [ClaudePermissionPresentation.Context(threadID: "other", turnID: "turn-A", workspacePath: "/B"), .init(threadID: "thread-A", turnID: "other", workspacePath: nil)] {
            let b = ClaudePermissionPresentation.make(from: value, context: next)
            XCTAssertNotEqual(a.id, b.id); XCTAssertNotEqual(a.details[0].id, b.details[0].id)
        }
    }
}
