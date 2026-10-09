import Foundation

public enum AgentCLIExecutionError: Error, LocalizedError {
	case commandNotFound(String)
	case spawnFailed(String)
	case inputEncodingFailed
	case inputWriteFailed(String)
	case waitFailed(String)

	public var errorDescription: String? {
		switch self {
		case .commandNotFound(let command):
			return "Command not found: \(command)"
		case .spawnFailed(let message):
			return message
		case .inputEncodingFailed:
			return "Failed to encode input for process"
		case .inputWriteFailed(let message):
			return message
		case .waitFailed(let message):
			return "waitpid failed: \(message)"
		}
	}
}
