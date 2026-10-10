/// Result of a host's executable launchability check. No lookup or I/O occurs here.
public enum AgentExecutableLaunchability: Equatable, Sendable {
    case launchable, bareCommandFallback, missingPath, directory, notExecutable
}
