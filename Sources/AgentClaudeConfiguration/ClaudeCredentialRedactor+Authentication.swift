import Foundation
import ClaudeRuntimeKit

// Authentication-value redaction and durable, secret-free run metadata.

extension ClaudeCredentialRedactor {
	/// Scrubs `KEY=value` assignments in a flat log line (e.g. an env dump),
	/// replacing the value with `placeholder`. A key is scrubbed when it is one of
	/// the Anthropic/backend variables that can redirect authentication, or when
	/// `ClaudeRedactedEnvironmentSnapshot.isSecretBearing` (the one env-name
	/// predicate, which also folds in the structural `isSensitiveKey`) says so.
	/// A double- or single-quoted value is scrubbed whole, whitespace included.
	/// Complements the key-based structural `redact(_:)` used for JSON payloads.
	public static func redactAuthenticationValues(in text: String) -> String {
		let pattern = #"([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|'[^']*'|\S*)"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
		let nsText = text as NSString
		var result = ""
		var cursor = 0
		for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
			let name = nsText.substring(with: match.range(at: 1))
			guard ClaudeLaunchEnvironmentSanitizer.conflictingKeys.contains(name)
					|| ClaudeRedactedEnvironmentSnapshot.isSecretBearing(name) else { continue }
			let value = match.range(at: 2)
			result += nsText.substring(with: NSRange(location: cursor, length: value.location - cursor))
			result += placeholder
			cursor = value.location + value.length
		}
		result += nsText.substring(from: cursor)
		return result
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
