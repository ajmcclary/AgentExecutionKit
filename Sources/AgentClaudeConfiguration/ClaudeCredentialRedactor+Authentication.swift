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
		var searchFrom = 0
		while searchFrom < nsText.length,
			  let match = regex.firstMatch(in: text, range: NSRange(location: searchFrom, length: nsText.length - searchFrom)) {
			let name = nsText.substring(with: match.range(at: 1))
			let value = match.range(at: 2)
			guard ClaudeLaunchEnvironmentSanitizer.conflictingKeys.contains(name)
					|| ClaudeRedactedEnvironmentSnapshot.isSecretBearing(name) else {
				// Not secret: rescan inside its value, which may itself carry an
				// assignment (`env=ANTHROPIC_API_KEY=…`, `CMD="KEY=… cmd"`).
				searchFrom = value.location > match.range.location ? value.location : match.range.location + 1
				continue
			}
			result += nsText.substring(with: NSRange(location: cursor, length: value.location - cursor))
			result += placeholder
			cursor = value.location + value.length
			searchFrom = max(cursor, value.location + 1)
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
