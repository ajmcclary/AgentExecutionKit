/// Selects the semantic projection only. Lifecycle and usage identity authority
/// remain the same in both modes. Hosts resolve preferences explicitly and
/// capture the chosen value for the lifetime of their content pipeline.
public enum ClaudeProjectionAuthority: String, CaseIterable, Sendable {
	case normalized
	case legacy
}
