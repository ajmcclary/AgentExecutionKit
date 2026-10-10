import Foundation
import AIClientKit
import AgentRuntimeKit
import ClaudeRuntimeKit

public enum ClaudeNativeTurnStatus: Sendable { case completed, cancelled, failed }
public struct ClaudeNativeSessionRef: Sendable {
	public var sessionID: String?
	public init(sessionID: String?) { self.sessionID = sessionID }
}
public struct ClaudeRuntimeInitStatus: Sendable, Equatable {
	public struct InitializeResponseSnapshot: Sendable, Equatable {
		public struct Command: Sendable, Equatable {
			public let name: String, description: String, argumentHint: String
			public init(name: String, description: String, argumentHint: String) {
				self.name = name; self.description = description; self.argumentHint = argumentHint
			}
		}
		public struct Agent: Sendable, Equatable {
			public let name: String, description: String
			public let model: String?
			public init(name: String, description: String, model: String?) {
				self.name = name; self.description = description; self.model = model
			}
		}
		public struct Account: Sendable, Equatable {
			public let email: String?, organization: String?, subscriptionType: String?, tokenSource: String?, apiKeySource: String?, apiProvider: String?
			public init(email: String?, organization: String?, subscriptionType: String?, tokenSource: String?, apiKeySource: String?, apiProvider: String?) {
				self.email = email; self.organization = organization; self.subscriptionType = subscriptionType
				self.tokenSource = tokenSource; self.apiKeySource = apiKeySource; self.apiProvider = apiProvider
			}
		}
		public let commands: [Command], agents: [Agent]
		public let outputStyle: String?, availableOutputStyles: [String], account: Account?, pid: Int?, modelsJSON: String?, fastModeStateJSON: String?
		public init(commands: [Command], agents: [Agent], outputStyle: String?, availableOutputStyles: [String], account: Account?, pid: Int?, modelsJSON: String?, fastModeStateJSON: String?) {
			self.commands = commands; self.agents = agents; self.outputStyle = outputStyle; self.availableOutputStyles = availableOutputStyles
			self.account = account; self.pid = pid; self.modelsJSON = modelsJSON; self.fastModeStateJSON = fastModeStateJSON
		}
	}
	public let sessionID: String?, tools: [String], mcpServerStatuses: [String: String], initializeResponse: InitializeResponseSnapshot?
	public init(sessionID: String?, tools: [String], mcpServerStatuses: [String: String], initializeResponse: InitializeResponseSnapshot?) {
		self.sessionID = sessionID; self.tools = tools; self.mcpServerStatuses = mcpServerStatuses; self.initializeResponse = initializeResponse
	}
	/// Server identity is supplied by the host; existing case-insensitive matching
	/// and native failure-state normalization are preserved.
	public func serverStatus(named name: String) -> String? {
		mcpServerStatuses.first { $0.key.compare(name, options: .caseInsensitive) == .orderedSame }?.value
	}
	public func isServerFailed(named name: String) -> Bool {
		serverStatus(named: name)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "failed"
	}
}
public enum ClaudeNativeEvent: Sendable {
	case stream(AIStreamResult)
	case runtimeInit(ClaudeRuntimeInitStatus)
	case approvalRequest(AgentApprovalRequest)
	case approvalCancelled(requestID: String)
	case turnCompleted(turnID: UUID, status: ClaudeNativeTurnStatus)
	/// Identity only; emitted immediately before its aggregate message_stop. It
	/// creates no transcript/persistence row or UI refresh by itself.
	case turnAggregateIdentity(ClaudeUsageIdentity)
	case error(String)
}
