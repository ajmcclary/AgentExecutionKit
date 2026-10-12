import Foundation
import AgentProcessSupport
import AgentClaudeProtocol

/// Provider wire/launch policy with explicit host configuration. Environment
/// reads, credentials, executable discovery and preference lookup stay in hosts.
public enum ClaudeNativeSessionContract {
    public struct LaunchOptions: Sendable {
        public let permissionMode: String
        public let mcpConfigurationURL: URL?
        public let strictMCP: Bool
        public let disallowedBuiltInTools: [String]
        public init(permissionMode: String, mcpConfigurationURL: URL?, strictMCP: Bool, disallowedBuiltInTools: [String]) {
            self.permissionMode = permissionMode; self.mcpConfigurationURL = mcpConfigurationURL
            self.strictMCP = strictMCP; self.disallowedBuiltInTools = disallowedBuiltInTools
        }
    }
    /// Model/effort are control settings, never native CLI arguments. Resume
    /// identifiers and disallowed-tool order retain the original raw values.
    public static func arguments(existingSessionID: String?, options: LaunchOptions) -> [String] {
        var args = ["-p", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json",
                    "--permission-prompt-tool", "stdio"]
        if let existingSessionID, !existingSessionID.isEmpty { args.append(contentsOf: ["--resume", existingSessionID]) }
        let effectivePermissionMode = options.permissionMode
        if effectivePermissionMode.caseInsensitiveCompare("bypassPermissions") == .orderedSame {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let url = options.mcpConfigurationURL {
            args.append(contentsOf: ["--mcp-config", url.path])
            if options.strictMCP { args.append("--strict-mcp-config") }
        }
        if !options.disallowedBuiltInTools.isEmpty {
            args.append(contentsOf: ["--disallowedTools", options.disallowedBuiltInTools.joined(separator: ",")])
        }
        return args
    }
    /// Base -> native defaults -> host configuration -> resolver -> scrub.
    /// Tool-search opt-in preserves the base instead of forcing a true value.
    public static func environment(base: [String: String], toolSearchEnabled: Bool,
            configurationOverrides: [String: String], resolverOverrides: [String: String],
            resolverRemovedKeys: Set<String>) -> [String: String] {
        var env = base
        if env["CLAUDE_CODE_ENTRYPOINT"].map({ !$0.isEmpty }) != true { env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts" }
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        if !toolSearchEnabled { env["ENABLE_TOOL_SEARCH"] = "false" }
        for (key, value) in configurationOverrides { env[key] = value }
        for (key, value) in resolverOverrides { env[key] = value }
        return ProcessEnvironmentSanitizer.sanitizedForChildLaunch(env,
            additionalRemovedKeys: Set(["NODE_OPTIONS"]).union(resolverRemovedKeys))
    }
    /// Absent and explicitly empty prompts are distinct; permission mode is a
    /// separate round trip, not a field in initialize.
    public static func initializeRequest(systemPromptOverride: String?) throws -> ClaudeProtocolJSONObject {
        var request: [String: Any] = ["subtype": "initialize"]
        if let systemPromptOverride { request["systemPrompt"] = systemPromptOverride }
        return try .init(object: request)
    }
    /// The host's persisted default-model identity is injected, not looked up.
    public static func flagSettingsRequest(model: String?, effortLevel: String?, defaultModelIdentifier: String) throws -> ClaudeProtocolJSONObject? {
        var settings: [String: String] = [:]
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.caseInsensitiveCompare(defaultModelIdentifier) != .orderedSame { settings["model"] = trimmed }
        if let effortLevel { settings["effortLevel"] = effortLevel }
        guard !settings.isEmpty else { return nil }
        return try .init(object: ["subtype": "apply_flag_settings", "settings": settings])
    }
    public static func permissionModeRequest(effectivePermissionMode: String) throws -> ClaudeProtocolJSONObject? {
        let trimmed = effectivePermissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try .init(object: ["subtype": "set_permission_mode", "mode": trimmed])
    }
}
