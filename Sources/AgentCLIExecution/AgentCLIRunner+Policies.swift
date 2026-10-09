import Foundation
import Darwin
import ProcessKit

extension AgentCLIRunner {
	public static func applyOutputMode(_ arguments: inout [String], outputMode: OutputFlagMode) {
		switch outputMode {
		case .auto(let format):
			if let existing = arguments.firstIndex(of: "--output-format") {
				let valueIndex = arguments.index(after: existing)
				if valueIndex < arguments.count {
					arguments[valueIndex] = format.rawValue
				} else {
					arguments.append(format.rawValue)
				}
			} else {
				arguments.append(contentsOf: format.tokens)
			}
		case .none:
			break
		case .custom(let tokens):
			arguments.append(contentsOf: tokens)
		}
	}

	/// Redacts sensitive prompt/system-prompt argument values for debug logging.
	/// Single-sourced so the buffered and streaming launch paths cannot diverge.
	public static func sanitizedLaunchArguments(_ arguments: [String]) -> [String] {
		let sensitiveFlags: Set<String> = [
			"--append-system-prompt",
			"--system-prompt",
			"--prompt"
		]
		return arguments.enumerated().map { index, arg -> String in
			if index > 0, sensitiveFlags.contains(arguments[index - 1]) {
				return "<redacted>"
			}
			if arg.contains("<file_map>")
				|| arg.contains("<user_instructions>")
				|| arg.contains("<discover_instructions>")
				|| arg.contains("<metadata>")
				|| arg.contains("\n")
				|| arg.count > 120 {
				return "<redacted>"
			}
			return arg
		}
	}

	func mapLauncherError(
		_ error: ProcessLauncherError,
		command: String,
		workingDirectory: String?
	) -> AgentCLIExecutionError {
		switch error {
		case .pipeCreationFailed(let pipe):
			return .spawnFailed("Failed to create \(pipe) pipe for process startup")
		case .changeDirectoryFailed(let path, let errnoValue):
			let message = String(cString: strerror(errnoValue))
			return .spawnFailed("Unable to set working directory to \(path): \(message)")
		case .spawnAttributesFailed(let operation, let errnoValue):
			let message = String(cString: strerror(errnoValue))
			if let workingDirectory {
				return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command) in \(workingDirectory): \(message)")
			}
			return .spawnFailed("Failed to configure spawn attributes (\(operation)) for \(command): \(message)")
		case .spawnFailed(let errnoValue):
			if errnoValue == ENOENT {
				return .commandNotFound(command)
			}
			let message = String(cString: strerror(errnoValue))
			if let workingDirectory {
				return .spawnFailed("Failed to launch \(command) in \(workingDirectory): \(message)")
			}
			return .spawnFailed("Failed to launch \(command): \(message)")
		}
	}

}
