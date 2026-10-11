import Foundation

public enum ClaudeCompatibleEnvironmentPolicy {
    public struct SlotMapping: Equatable, Sendable {
        public let haiku: String, sonnet: String, opus: String
        public init(haiku: String, sonnet: String, opus: String) {
            self.haiku = haiku; self.sonnet = sonnet; self.opus = opus
        }
    }
    public static func removedKeys(authVariableName: String) -> Set<String> {
        Set(["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"].filter { $0 != authVariableName })
    }
    public static func environment(baseURL: String, authVariableName: String, credential: String,
                                   timeoutMilliseconds: String?, slotMapping: SlotMapping?) -> [String: String] {
        var result = ["ANTHROPIC_BASE_URL": baseURL, authVariableName: credential]
        if let timeoutMilliseconds { result["API_TIMEOUT_MS"] = timeoutMilliseconds }
        if let slotMapping {
            let haiku = slotMapping.haiku.trimmingCharacters(in: .whitespacesAndNewlines)
            result["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = haiku
            result["ANTHROPIC_DEFAULT_SONNET_MODEL"] = slotMapping.sonnet.trimmingCharacters(in: .whitespacesAndNewlines)
            result["ANTHROPIC_DEFAULT_OPUS_MODEL"] = slotMapping.opus.trimmingCharacters(in: .whitespacesAndNewlines)
            result["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "1000000"
            result["CLAUDE_CODE_SUBAGENT_MODEL"] = haiku
        }
        return result
    }
}
