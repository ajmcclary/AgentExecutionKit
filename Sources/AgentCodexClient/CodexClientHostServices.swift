import Foundation
import ProcessKit

/// Feature selection is separate from the host's concrete CLI override policy.
public struct CodexProcessFeaturePolicy: Sendable, Equatable {
	public var goalsEnabled: Bool
	public var computerUseEnabled: Bool
	public init(goalsEnabled: Bool, computerUseEnabled: Bool) {
		self.goalsEnabled = goalsEnabled
		self.computerUseEnabled = computerUseEnabled
	}
	public static let defaultDisabled = Self(goalsEnabled: false, computerUseEnabled: false)
	public static let enabledForGoals = Self(goalsEnabled: true, computerUseEnabled: false)
	public static let enabledForComputerUse = Self(goalsEnabled: false, computerUseEnabled: true)
	public static func resolved(goalsEnabled: Bool, computerUseEnabled: Bool) -> Self {
		Self(goalsEnabled: goalsEnabled, computerUseEnabled: computerUseEnabled)
	}
}

extension CodexAgentClient {
	public struct ClientIdentity: Sendable, Equatable {
		public let name: String
		public let title: String
		public let version: String
		public init(name: String, title: String, version: String) {
			self.name = name
			self.title = title
			self.version = version
		}
	}

	/// A resolved, per-start launch snapshot. No executable or environment discovery
	/// occurs implicitly in the shared client.
	public struct LaunchSpecification: Sendable, Equatable {
		public let command: String
		public let arguments: [String]
		public let environment: [String: String]
		public let workingDirectory: String?
		public init(command: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
			self.command = command
			self.arguments = arguments
			self.environment = environment
			self.workingDirectory = workingDirectory
		}
	}

	public struct HostServices: Sendable {
		public let clientIdentity: ClientIdentity
		public let prepareLaunch: @Sendable (Config) async throws -> LaunchSpecification
		public let terminationPolicy: @Sendable () -> ProcessTerminationPolicy
		public let diagnostics: @Sendable (String) -> Void
		public let readErrorCode: @Sendable (any Error) -> Int32?
		public init(
			clientIdentity: ClientIdentity,
			prepareLaunch: @escaping @Sendable (Config) async throws -> LaunchSpecification,
			terminationPolicy: @escaping @Sendable () -> ProcessTerminationPolicy,
			diagnostics: @escaping @Sendable (String) -> Void,
			readErrorCode: @escaping @Sendable (any Error) -> Int32?
		) {
			self.clientIdentity = clientIdentity
			self.prepareLaunch = prepareLaunch
			self.terminationPolicy = terminationPolicy
			self.diagnostics = diagnostics
			self.readErrorCode = readErrorCode
		}
	}
}
