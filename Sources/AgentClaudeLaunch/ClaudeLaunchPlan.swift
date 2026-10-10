import Foundation
import AgentClaudeProtocol

/// Immutable execution artifact. Context is a host's typed authentication/backend
/// evidence; the shared builder never reads preferences or credentials itself.
public struct ClaudeNativeLaunchPlan<Context: Sendable>: Sendable {
	public let resolvedCommand: String
	public let arguments: [String]
	public let environment: [String: String]
	public let workingDirectory: String
	public let launchEnvironment: Context
	public let flagSettingsRequest: ClaudeProtocolJSONObject?
	public init(resolvedCommand: String, arguments: [String], environment: [String: String], workingDirectory: String,
		launchEnvironment: Context, flagSettingsRequest: ClaudeProtocolJSONObject?) {
		self.resolvedCommand = resolvedCommand; self.arguments = arguments; self.environment = environment
		self.workingDirectory = workingDirectory; self.launchEnvironment = launchEnvironment; self.flagSettingsRequest = flagSettingsRequest
	}
}
public struct ClaudeLaunchFlagResolution<Context: Sendable>: Sendable {
	public let launchEnvironment: Context
	public let environmentOverrides: [String: String]
	public let removedEnvironmentKeys: Set<String>
	public let request: ClaudeProtocolJSONObject?
	public init(launchEnvironment: Context, environmentOverrides: [String: String], removedEnvironmentKeys: Set<String>, request: ClaudeProtocolJSONObject?) {
		self.launchEnvironment = launchEnvironment; self.environmentOverrides = environmentOverrides
		self.removedEnvironmentKeys = removedEnvironmentKeys; self.request = request
	}
}

/// Ordering owner: flags, environment, one command resolution, argv, then cwd.
/// Callbacks remain confined to the caller's isolation domain.
public struct ClaudeNativeLaunchPlanBuilder<Context: Sendable, Effort: Sendable> {
	public struct Collaborators {
		public let resolveFlagSettings: (String?, Effort?) async throws -> ClaudeLaunchFlagResolution<Context>
		public let composeEnvironment: ([String: String], Set<String>) async -> [String: String]
		public let resolveCommand: ([String: String]) -> String
		public let buildArguments: (String?) -> [String]
		public let workingDirectory: () -> String
		public init(resolveFlagSettings: @escaping (String?, Effort?) async throws -> ClaudeLaunchFlagResolution<Context>,
			composeEnvironment: @escaping ([String: String], Set<String>) async -> [String: String],
			resolveCommand: @escaping ([String: String]) -> String, buildArguments: @escaping (String?) -> [String], workingDirectory: @escaping () -> String) {
			self.resolveFlagSettings = resolveFlagSettings; self.composeEnvironment = composeEnvironment
			self.resolveCommand = resolveCommand; self.buildArguments = buildArguments; self.workingDirectory = workingDirectory
		}
	}
	private let collaborators: Collaborators
	public init(collaborators: Collaborators) { self.collaborators = collaborators }
	public nonisolated(nonsending) func build(existingSessionID: String?, model: String?, effortLevel: Effort?) async throws -> ClaudeNativeLaunchPlan<Context> {
		let flags = try await collaborators.resolveFlagSettings(model, effortLevel)
		let environment = await collaborators.composeEnvironment(flags.environmentOverrides, flags.removedEnvironmentKeys)
		let command = collaborators.resolveCommand(environment)
		let arguments = collaborators.buildArguments(existingSessionID)
		return .init(resolvedCommand: command, arguments: arguments, environment: environment, workingDirectory: collaborators.workingDirectory(),
			launchEnvironment: flags.launchEnvironment, flagSettingsRequest: flags.request)
	}
}
