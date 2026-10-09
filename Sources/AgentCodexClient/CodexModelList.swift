import Foundation

public struct CodexModelListParams: Encodable, Sendable {
	public let limit: Int
	public let cursor: String?
	public init(limit: Int, cursor: String?) { self.limit = limit; self.cursor = cursor }
}

public struct CodexModelUpgradeInfoPayload: Decodable, Equatable, Sendable {
	public let model: String?
	public let upgradeCopy: String?
	public let migrationMarkdown: String?
	public let modelLink: String?
}

public struct CodexModelServiceTierPayload: Decodable, Equatable, Sendable {
	public let id: String?
}

public struct CodexModelInfo: Decodable, Equatable, Sendable {
	// All optional to preserve the hand-parser's tolerance: a sparse entry never
	// fails the whole page; missing fields fall back at the mapping site.
	public let id: String?
	public let model: String?
	public let displayName: String?
	public let description: String?
	public let isDefault: Bool?
	public let supportedReasoningEfforts: [ReasoningEffort]?
	public let defaultReasoningEffort: String?
	/// Advisory successor metadata (`upgrade`/`upgradeInfo`) — retained for
	/// migration prompts, never for automatic substitution.
	public let upgrade: String?
	public let upgradeInfo: CodexModelUpgradeInfoPayload?
	public let serviceTiers: [CodexModelServiceTierPayload]?
	public struct ReasoningEffort: Decodable, Equatable, Sendable { public let reasoningEffort: String; public let description: String }
}
public struct CodexModelListResult: Decodable, Equatable, Sendable { public let data: [CodexModelInfo]; public let nextCursor: String? }



/// Bridges typed Codable models to the actor transport's `[String: Any]`.
/// `nil` fields are omitted (encoder default), matching the hand-built dicts.
public enum CodexClientCodableBridge {
	public static func dictionary<T: Encodable>(from value: T) throws -> [String: Any] {
		let data = try JSONEncoder().encode(value)
		let object = try JSONSerialization.jsonObject(with: data)
		return (object as? [String: Any]) ?? [:]
	}

	public static func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) throws -> T {
		let data = try JSONSerialization.data(withJSONObject: dict)
		return try JSONDecoder().decode(T.self, from: data)
	}
}
