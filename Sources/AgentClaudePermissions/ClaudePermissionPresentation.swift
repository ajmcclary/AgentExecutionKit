import Foundation
import AgentRuntimeKit
import AgentClaudeProtocol

/// Portable native approval projection. Hosts own authorization and supply
/// their stable thread/turn/workspace context; unknown tools retain generic cards.
public enum ClaudePermissionPresentation {
    public struct Context: Sendable {
        public let threadID: String
        public let turnID: String
        public let workspacePath: String?
        public init(threadID: String, turnID: String, workspacePath: String?) {
            self.threadID = threadID; self.turnID = turnID; self.workspacePath = workspacePath
        }
    }
	public static func make(from request: ClaudeNativeProtocolCodec.ControlRequest, context: Context) -> AgentApprovalRequest {
		let payload = (try? request.request.dictionary()) ?? [:]
		let toolName = (payload["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
		let input = payload["input"] as? [String: Any] ?? [:]
		let blockedPath = payload["blocked_path"] as? String
		let decisionReason = payload["decision_reason"] as? String
		let description = payload["description"] as? String
		let toolUseID = (payload["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

		let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let normalizedTool = toolName.lowercased()
		let kind: AgentApprovalKind = normalizedTool.contains("bash") || normalizedTool.contains("shell")
			? .commandExecution
			: .fileChange

		let threadID = context.threadID
		let turnID = context.turnID
		let itemID = (toolUseID?.isEmpty == false ? toolUseID! : request.requestID)

		let approvalID = AgentApprovalRequest.stableID(
			requestID: .claudeControl(request.requestID),
			method: "control/can_use_tool",
			kind: kind,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID
		)
		let detailSeed = approvalID.uuidString
		var details: [AgentApprovalDetail] = []
		var detailIndex = 0
		func appendDetail(label: String, value: String, isCode: Bool = false) {
			details.append(
				AgentApprovalDetail(
					id: AgentApprovalDetail.stableID(
						requestSeed: detailSeed,
						index: detailIndex,
						label: label,
						value: value,
						isCode: isCode
					),
					label: label,
					value: value,
					isCode: isCode
				)
			)
			detailIndex += 1
		}
		appendDetail(label: "Tool", value: toolName, isCode: true)
		if let command, !command.isEmpty {
			appendDetail(label: "Command", value: command, isCode: true)
		}
		if let blockedPath, !blockedPath.isEmpty {
			appendDetail(label: "Blocked Path", value: blockedPath, isCode: true)
		}
		if let decisionReason, !decisionReason.isEmpty {
			appendDetail(label: "Reason", value: decisionReason)
		}
		if let description, !description.isEmpty {
			appendDetail(label: "Description", value: description)
		}

		return AgentApprovalRequest(
			id: approvalID,
			requestID: .claudeControl(request.requestID),
			method: "control/can_use_tool",
			kind: kind,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID,
			reason: decisionReason,
			command: command,
			cwd: context.workspacePath,
			grantRoot: blockedPath,
			details: details
		)
	}

}
