import Foundation
import ProcessKit

public protocol AgentCLILogSink: Sendable {
	func append(_ message: String)
	func appendSection(title: String, content: String)
	func appendDataSection(title: String, data: Data)
}

public enum AgentCLIOutputFormat: String, Sendable {
	case text, json
	case streamJson = "stream-json"
	public var tokens: [String] { ["--output-format", rawValue] }
}

public struct AgentCLIConfiguration: Sendable {
	public var command: String
	public var workingDirectory: String
	public var environment: [String: String]
	public var additionalPaths: [String]
	public var commandSuffix: [String]
	public var enableDebugLogging: Bool
	public var logCollector: (any AgentCLILogSink)?
	public var resolveCandidates: [String]?
	public var captureStdoutTailBytes: Int
	public var captureStderrTailBytes: Int
	public var logStdinSampleBytes: Int
	public init(command: String, workingDirectory: String, additionalPaths: [String],
		environment: [String: String] = [:], commandSuffix: [String] = [], enableDebugLogging: Bool = false,
		logCollector: (any AgentCLILogSink)? = nil, resolveCandidates: [String]? = nil,
		captureStdoutTailBytes: Int = 0, captureStderrTailBytes: Int = 256 * 1024, logStdinSampleBytes: Int = 0) {
		self.command = command; self.workingDirectory = workingDirectory; self.environment = environment
		self.additionalPaths = additionalPaths; self.commandSuffix = commandSuffix; self.enableDebugLogging = enableDebugLogging
		self.logCollector = logCollector; self.resolveCandidates = resolveCandidates
		self.captureStdoutTailBytes = captureStdoutTailBytes; self.captureStderrTailBytes = captureStderrTailBytes
		self.logStdinSampleBytes = logStdinSampleBytes
	}
}

extension AgentCLIRunner {
	public struct HostServices: Sendable {
		public let environment: @Sendable (AgentCLIConfiguration, [String: String], Set<String>) async throws -> [String: String]
		public let resolveCommand: @Sendable (AgentCLIConfiguration, [String: String]) async throws -> String
		public let expandWorkingDirectory: @Sendable (String, [String: String]) -> String
		public let rememberSuccessfulCommand: @Sendable (String, String) async -> Void
		public let terminationPolicy: @Sendable () -> ProcessTerminationPolicy
		public let diagnostics: @Sendable (String) -> Void
		public let readPreflight: @Sendable (Int32, String) throws -> Void
		public let didStart: @Sendable (UUID, Int32) async -> Void
		public let didFinish: @Sendable (UUID, Int32) async -> Void
		public init(
			environment: @escaping @Sendable (AgentCLIConfiguration, [String: String], Set<String>) async throws -> [String: String],
			resolveCommand: @escaping @Sendable (AgentCLIConfiguration, [String: String]) async throws -> String,
			expandWorkingDirectory: @escaping @Sendable (String, [String: String]) -> String,
			rememberSuccessfulCommand: @escaping @Sendable (String, String) async -> Void,
			terminationPolicy: @escaping @Sendable () -> ProcessTerminationPolicy,
			diagnostics: @escaping @Sendable (String) -> Void,
			readPreflight: @escaping @Sendable (Int32, String) throws -> Void,
			didStart: @escaping @Sendable (UUID, Int32) async -> Void = { _, _ in },
			didFinish: @escaping @Sendable (UUID, Int32) async -> Void = { _, _ in }
		) {
			self.environment = environment; self.resolveCommand = resolveCommand
			self.expandWorkingDirectory = expandWorkingDirectory; self.rememberSuccessfulCommand = rememberSuccessfulCommand
			self.terminationPolicy = terminationPolicy; self.diagnostics = diagnostics; self.readPreflight = readPreflight
			self.didStart = didStart; self.didFinish = didFinish
		}
	}
}
