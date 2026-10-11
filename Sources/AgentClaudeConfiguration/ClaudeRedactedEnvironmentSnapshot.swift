import Foundation

// R15j. A launch environment cannot be handed to a test as a raw dictionary.
//
// This exists because a real credential WAS disclosed: an `XCTAssertEqual` over a
// composed compatible-backend environment failed and printed a live Z.ai
// `ANTHROPIC_AUTH_TOKEN` into test output. A synthetic BASE environment does not
// prevent that — the secret arrives through the resolver's overrides, which are
// fetched for real.
//
// A test-side denylist is not a fix: it is opt-in, easy to omit, and was scoped to
// three Anthropic variables while the app supports seven authentication families.
// Redaction belongs at the boundary, in the type the seam returns.

/// A launch environment safe to assert on and safe to print.
///
/// Carries the complete key set and the exact values of non-secret variables;
/// secret-bearing keys are represented by NAME only. There is deliberately no
/// accessor returning a secret value — the type cannot disclose one.
public struct ClaudeRedactedEnvironmentSnapshot: Equatable, Sendable, CustomStringConvertible {
	/// Every key present, secret or not.
	public let allKeys: Set<String>
	/// Exact values for non-secret keys only.
	public let nonSecretValues: [String: String]
	/// Keys whose values were withheld.
	public let secretKeys: Set<String>

	public init(environment: [String: String]) {
		var nonSecret: [String: String] = [:]
		var secrets: Set<String> = []
		for (key, value) in environment {
			if Self.isSecretBearing(key) {
				secrets.insert(key)
			} else {
				nonSecret[key] = value
			}
		}
		self.allKeys = Set(environment.keys)
		self.nonSecretValues = nonSecret
		self.secretKeys = secrets
	}

	/// Presence without disclosure.
	public func containsSecret(_ key: String) -> Bool { secretKeys.contains(key) }

	/// Never interpolates a secret value.
	public var description: String {
		let nonSecret = nonSecretValues.keys.sorted()
			.map { "\($0)=\(nonSecretValues[$0] ?? "")" }
			.joined(separator: ", ")
		return "ClaudeRedactedEnvironmentSnapshot(nonSecret: [\(nonSecret)], "
			+ "secretKeys: \(secretKeys.sorted()))"
	}

	/// Covers every authentication family the app supports — Anthropic direct,
	/// Bedrock, Vertex AI, Foundry, enterprise gateway, and compatible backends —
	/// plus generic credential-shaped names.
	///
	/// Deliberately over-broad: redacting a non-secret costs a less precise
	/// assertion, while missing a secret discloses it.
	public static func isSecretBearing(_ key: String) -> Bool {
		let upper = key.uppercased()

		// Names that contain a marker substring but are numeric LIMITS, not
		// credentials. Kept deliberately tiny and exact: every entry weakens the
		// heuristic, so a new one needs to be obviously a count or a size.
		let knownNonSecret: Set<String> = [
			"MAX_MCP_OUTPUT_TOKENS",
			"CLAUDE_CODE_MAX_OUTPUT_TOKENS",
			"MAX_THINKING_TOKENS"
		]
		if knownNonSecret.contains(upper) { return false }

		let exact: Set<String> = [
			// Anthropic direct
			"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
			"ANTHROPIC_CUSTOM_HEADERS",
			// Amazon Bedrock
			"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
			"AWS_PROFILE", "AWS_BEARER_TOKEN_BEDROCK",
			// Google Vertex AI
			"GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_API_KEY",
			"CLOUD_ML_REGION", "ANTHROPIC_VERTEX_PROJECT_ID",
			// Azure / Foundry
			"AZURE_API_KEY", "AZURE_OPENAI_API_KEY", "FOUNDRY_API_KEY"
		]
		if exact.contains(upper) { return true }
		// Generic credential-shaped names, e.g. a compatible backend's own token.
		for marker in ["TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "APIKEY", "API_KEY"]
		where upper.contains(marker) {
			return true
		}
		return false
	}
}
