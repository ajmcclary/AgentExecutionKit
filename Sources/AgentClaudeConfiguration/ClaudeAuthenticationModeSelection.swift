import Foundation

/// The SINGLE decision that turns a runtime variant plus credential state into a
/// `ClaudeAuthenticationMode`.
///
/// Why one function and not three
/// ------------------------------
/// A first version of this seam exposed `standard(hasAppOwnedAnthropicKey:)`,
/// `compatible(label:)` and a separate `reachableModes(for:)`. That is three
/// decisions wearing one type's name, and review demonstrated the gap: the
/// standard resolver branch could be changed to call `compatible(...)` directly,
/// and because `reachableModes(.standard)` was written independently, it still
/// reported API-key/subscription. The boundary gate passed, the census passed,
/// and the reachable standard profiles were wrong.
///
/// So there is now exactly ONE producer, `select(variant:credentialState:)`, and
/// enumeration is DERIVED from it — `reachableModes` maps `reachableStates`
/// through `select`, so it cannot disagree with what the resolver gets. Changing
/// what `select` returns for a variant changes the census in the same edit.
///
/// Boundary rule **A4** (`Scripts/verify-claude-auth-reachability.py`) enforces
/// two things: the resolver constructs no `ClaudeAuthenticationMode` directly,
/// and it reaches this seam only through `select(...)`.
public enum ClaudeAuthenticationModeSelection {
	public enum Variant: Equatable, Sendable { case standard, compatible }

	/// What credential the app has available for this launch. Deliberately not a
	/// credential VALUE — only its provenance class.
	public enum CredentialState: Equatable, Sendable {
		/// RepoPrompt holds an Anthropic API key for this run.
		case appOwnedAnthropicKey
		/// No app-owned credential; the user's own Claude Code session authenticates.
		case userManagedSession
		/// A Claude-compatible backend's own credential, labelled for display.
		case compatibleBackend(label: String)
	}

	/// The one producer. Every launch authentication mode comes from here.
	///
	/// Variant is matched FIRST, so a credential state that cannot occur for a
	/// variant cannot silently produce that variant's mode: a compatible-backend
	/// credential presented for the standard runtime does not make the standard
	/// runtime a compatible one.
	public static func select(
		variant: Variant,
		credentialState: CredentialState
	) -> ClaudeAuthenticationMode {
		switch variant {
		case .standard:
			switch credentialState {
			case .appOwnedAnthropicKey:
				return .anthropicAPIKey
			case .userManagedSession, .compatibleBackend:
				// Standard Claude has no backend credential; absence of an app-owned
				// key means the user's own session owns authentication.
				return .externalUserManagedClaudeCLI
			}
		case .compatible:
			switch credentialState {
			case .compatibleBackend(let label):
				return .compatibleBackend(label: label)
			case .appOwnedAnthropicKey, .userManagedSession:
				// A compatible backend always authenticates with its own credential.
				return .compatibleBackend(label: "")
			}
		}
	}

	/// The credential states a variant can actually present.
	public static func reachableStates(
		for variant: Variant,
		credentialLabel: String
	) -> [CredentialState] {
		switch variant {
		case .standard:
			return [.appOwnedAnthropicKey, .userManagedSession]
		case .compatible:
			return [.compatibleBackend(label: credentialLabel)]
		}
	}

	/// Every mode a variant can produce — DERIVED by mapping the reachable states
	/// through `select`, never restated. This is what the production-profile
	/// census enumerates.
	public static func reachableModes(
		for variant: Variant,
		credentialLabel: String
	) -> [ClaudeAuthenticationMode] {
		reachableStates(for: variant, credentialLabel: credentialLabel)
			.map { select(variant: variant, credentialState: $0) }
	}
}
