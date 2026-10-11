import Foundation

/// Explicit credential mode for a Claude Code launch. Foundation-only; carries no secret.
///
/// Every Claude Code launch is classified into exactly one of these modes so the
/// launch policy can (a) construct the correct environment, (b) guarantee an
/// explicit mode never falls back to another credential source, and (c) persist a
/// secret-free class + label for diagnostics.
public enum ClaudeAuthenticationMode: Equatable, Sendable {
	case anthropicAPIKey
	case bedrock
	case vertexAI
	case foundry
	case enterpriseGateway
	case compatibleBackend(label: String)
	case externalUserManagedClaudeCLI

	/// True when the host owns and controls the credential for this run.
	/// Only the user-managed local CLI mode is not host-controlled.
	public var isExplicitHostControlled: Bool {
		if case .externalUserManagedClaudeCLI = self { return false }
		return true
	}

	/// Stable, secret-free identifier for persistence/telemetry.
	public var persistedClassIdentifier: String {
		switch self {
		case .anthropicAPIKey: return "anthropic_api_key"
		case .bedrock: return "bedrock"
		case .vertexAI: return "vertex_ai"
		case .foundry: return "foundry"
		case .enterpriseGateway: return "enterprise_gateway"
		case .compatibleBackend: return "compatible_backend"
		case .externalUserManagedClaudeCLI: return "external_user_managed_cli"
		}
	}

	/// Non-secret provider/account label, when the mode carries one.
	public var providerLabel: String? {
		if case .compatibleBackend(let label) = self { return label }
		return nil
	}
}
