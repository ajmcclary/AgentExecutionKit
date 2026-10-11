import Foundation
import ClaudeRuntimeKit

// Authentication-value redaction and durable, secret-free run metadata.

extension ClaudeCredentialRedactor {
	/// Scrubs `KEY=value` assignments for the Anthropic/backend credential
	/// variables in a flat log line (e.g. an env dump), replacing the value with
	/// `placeholder`. Complements the key-based structural `redact(_:)` used for
	/// JSON payloads.
	public static func redactAuthenticationValues(in text: String) -> String {
		let keys = ClaudeLaunchEnvironmentSanitizer.conflictingKeys
			.sorted() // deterministic alternation order
		guard !keys.isEmpty else { return text }
		let alternation = keys.joined(separator: "|")
		let pattern = "(\(alternation))=\\S*"
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return regex.stringByReplacingMatches(
			in: text, range: range, withTemplate: "$1=\(placeholder)"
		)
	}
}

/// Secret-free credential metadata persisted with a Claude run. Carries only the
/// credential class and an optional non-secret provider/account label — never a
/// secret. `Codable` so it can be written to a sidecar record for audit/restore.
public struct ClaudeRunCredentialMetadata: Equatable, Codable, Sendable {
	public let classIdentifier: String
	public let providerLabel: String?

	public init(mode: ClaudeAuthenticationMode) {
		self.classIdentifier = mode.persistedClassIdentifier
		self.providerLabel = mode.providerLabel
	}
}
