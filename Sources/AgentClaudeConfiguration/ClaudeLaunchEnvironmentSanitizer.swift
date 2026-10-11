import Foundation

/// Pure policy: turns a credential mode into the environment overrides and
/// removals a Claude Code child must launch with. No I/O, no secrets stored.
///
/// Invariants:
/// - An explicit host-controlled mode SETS its owned variables and REMOVES
///   every other conflicting one, so an ambient value can never take over.
/// - A key that is being set is never also listed for removal (contradiction guard).
/// - The user-managed local CLI mode injects nothing and preserves the user's own
///   Anthropic auth, but still strips variables that belong to other explicit modes.
public enum ClaudeLaunchEnvironmentSanitizer {
	/// Anthropic/backend variables that can redirect authentication.
	public static let conflictingKeys: Set<String> = [
		"ANTHROPIC_API_KEY",
		"ANTHROPIC_AUTH_TOKEN",
		"ANTHROPIC_BASE_URL",
		"ANTHROPIC_MODEL",
		"ANTHROPIC_DEFAULT_HAIKU_MODEL",
		"ANTHROPIC_DEFAULT_SONNET_MODEL",
		"ANTHROPIC_DEFAULT_OPUS_MODEL",
		"CLAUDE_CODE_USE_BEDROCK",
		"CLAUDE_CODE_USE_VERTEX",
		"CLAUDE_CODE_SKIP_BEDROCK_AUTH",
		"AWS_BEARER_TOKEN_BEDROCK",
	]

	/// In user-managed mode these are the user's own auth (subscription, own key,
	/// or own proxy) and MUST be preserved.
	public static let userPreservedKeys: Set<String> = [
		"ANTHROPIC_API_KEY",
		"ANTHROPIC_AUTH_TOKEN",
		"ANTHROPIC_BASE_URL",
	]

	public static func sanitize(
		mode: ClaudeAuthenticationMode,
		appOwnedOverrides: [String: String]
	) -> (overrides: [String: String], removedKeys: Set<String>) {
		switch mode {
		case .externalUserManagedClaudeCLI:
			// Inject nothing; strip only vars that belong to other explicit modes.
			return ([:], conflictingKeys.subtracting(userPreservedKeys))
		case .anthropicAPIKey, .bedrock, .vertexAI, .foundry, .enterpriseGateway, .compatibleBackend:
			// Explicit mode: set our owned vars, remove every other conflicting one.
			// Never remove a key we are setting.
			let removed = conflictingKeys.subtracting(appOwnedOverrides.keys)
			return (appOwnedOverrides, removed)
		}
	}
}
