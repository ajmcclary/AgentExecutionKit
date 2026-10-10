import Foundation
import AgentClaudeProtocol
import AgentClaudeEvents

public enum ClaudeMetadataCodec {
	public struct SystemInitFields: Equatable, Sendable {
		public let tools: [String]
		public let mcpStatuses: [String: String]
	}
	public static func parseInitializeResponse(_ response: ClaudeProtocolJSONObject) throws -> ClaudeRuntimeInitStatus.InitializeResponseSnapshot {
		parseInitializeDictionary(from: try response.dictionary())
	}
	public static func parseSystemInit(_ payload: ClaudeProtocolJSONObject) throws -> SystemInitFields? {
		parseSystemInitDictionary(from: try payload.dictionary())
	}
	public static func firstSessionIdentifier(_ payload: ClaudeProtocolJSONObject) throws -> String? {
		let value = try payload.dictionary()
		if let id = value["session_id"] as? String { return id }
		return value["sessionId"] as? String
	}
	private static func parseInitializeDictionary(
		from response: [String: Any]
	) -> ClaudeRuntimeInitStatus.InitializeResponseSnapshot {
		let commands: [ClaudeRuntimeInitStatus.InitializeResponseSnapshot.Command]
		if let rawCommands = response["commands"] as? [[String: Any]] {
			commands = rawCommands.compactMap { cmd in
				guard let name = cmd["name"] as? String, !name.isEmpty else { return nil }
				return .init(
					name: name,
					description: (cmd["description"] as? String) ?? "",
					argumentHint: (cmd["argumentHint"] as? String) ?? ""
				)
			}
		} else {
			commands = []
		}

		let agents: [ClaudeRuntimeInitStatus.InitializeResponseSnapshot.Agent]
		if let rawAgents = response["agents"] as? [[String: Any]] {
			agents = rawAgents.compactMap { agent in
				guard let name = agent["name"] as? String, !name.isEmpty else { return nil }
				return .init(
					name: name,
					description: (agent["description"] as? String) ?? "",
					model: agent["model"] as? String
				)
			}
		} else {
			agents = []
		}

		let account: ClaudeRuntimeInitStatus.InitializeResponseSnapshot.Account?
		if let rawAccount = response["account"] as? [String: Any] {
			account = .init(
				email: rawAccount["email"] as? String,
				organization: rawAccount["organization"] as? String,
				subscriptionType: rawAccount["subscriptionType"] as? String,
				tokenSource: rawAccount["tokenSource"] as? String,
				apiKeySource: rawAccount["apiKeySource"] as? String,
				apiProvider: rawAccount["apiProvider"] as? String
			)
		} else {
			account = nil
		}

		return .init(
			commands: commands,
			agents: agents,
			outputStyle: response["output_style"] as? String,
			availableOutputStyles: (response["available_output_styles"] as? [String]) ?? [],
			account: account,
			pid: response["pid"] as? Int,
			modelsJSON: Self.canonicalJSONString(from: response["models"]),
			fastModeStateJSON: Self.canonicalJSONString(from: response["fast_mode_state"])
		)
	}

	/// Returns a stable canonical JSON string for a value, or nil if the value is nil/not serializable.
	private static func canonicalJSONString(from value: Any?) -> String? {
		guard let value, !(value is NSNull) else { return nil }
		guard JSONSerialization.isValidJSONObject(["v": value]) else { return nil }
		guard let data = try? JSONSerialization.data(
			withJSONObject: value,
			options: [.sortedKeys, .fragmentsAllowed]
		) else { return nil }
		return String(data: data, encoding: .utf8)
	}

	private static func parseSystemInitDictionary(from payload: [String: Any]) -> SystemInitFields? {
		guard (payload["type"] as? String) == "system",
			((payload["subtype"] as? String)?.lowercased() == "init")
		else {
			return nil
		}

		let tools = (payload["tools"] as? [String]) ?? []
		var mcpStatuses: [String: String] = [:]
		if let mcpServers = payload["mcp_servers"] as? [[String: Any]] {
			for server in mcpServers {
				guard let name = server["name"] as? String,
					!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				else {
					continue
				}
				let status = (server["status"] as? String) ?? ""
				mcpStatuses[name] = status
			}
		}
		return SystemInitFields(tools: tools, mcpStatuses: mcpStatuses)
	}

}
