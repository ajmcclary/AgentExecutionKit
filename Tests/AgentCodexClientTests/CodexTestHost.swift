import Foundation
import Darwin
import AgentCodexClient
import CodexAppServerKit
import ProcessKit

typealias CodexAppServerClient = CodexAgentClient

enum CodexTestHost {
	static func validateFD(_ fd: Int32, label: String) throws {
		guard fd >= 0, fcntl(fd, F_GETFD) != -1 else { throw POSIXError(.EBADF) }
	}
	static let host = CodexAgentClient.HostServices(
		clientIdentity: .init(name: "fixture-host", title: "Fixture Host", version: "1"),
		prepareLaunch: { config in
			guard FileManager.default.isExecutableFile(atPath: config.commandName) else {
				throw CodexAgentClient.ClientError.executableUnavailable("Fixture executable unavailable")
			}
			return .init(command: config.commandName, arguments: ["app-server"],
						 environment: config.environmentOverrides, workingDirectory: config.workingDirectory)
		},
		terminationPolicy: { .init(cooperativeWaitTimeout: .seconds(3), sigtermGracePeriod: .seconds(2), sigkillGracePeriod: .seconds(1)) },
		diagnostics: { _ in },
		readErrorCode: { ($0 as? POSIXError)?.code.rawValue }
	)
}

extension CodexAgentClient {
	init(
		writeFrameHandler: @escaping @Sendable (Int32, Data) throws -> Void = { try FDWriteSupport.writeAll($1, to: $0) },
		livenessProbe: @escaping @Sendable (SpawnedProcess) -> Bool = { CodexAppServerProcessTransport.defaultProcessAppearsAlive($0) },
		expectedAgentPIDRegistrar: ExpectedAgentPIDRegistrar = .init(register: { _, _, _ in }, clear: { _, _, _ in }),
		readPreflight: @escaping @Sendable (Int32, String) throws -> Void = CodexTestHost.validateFD
	) {
		self.init(configuration: .init(commandName: "fixture-codex", additionalPathHints: []),
				  host: CodexTestHost.host, writeFrameHandler: writeFrameHandler, livenessProbe: livenessProbe,
				  expectedAgentPIDRegistrar: expectedAgentPIDRegistrar, readPreflight: readPreflight)
	}
}
