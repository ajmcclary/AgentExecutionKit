import Foundation

/// Describes how a host application process appears to have been launched.
///
/// This is intentionally narrower than a full process-environment builder: it is a
/// first-class signal that later launch code can use to decide whether inherited
/// environment variables are likely user-shell-rich or macOS app-launch-minimal.
public enum ProcessLaunchSource: Equatable, Sendable {
	case launchServices
	case xcode
	case terminalInherited
	case unknown
}

public struct ProcessLaunchContext: Equatable, Sendable {

	public let source: ProcessLaunchSource
	public let inheritedEnvironmentPath: String?
	public let shell: String?
	public let home: String?

	public init(source: ProcessLaunchSource, inheritedEnvironmentPath: String?, shell: String?, home: String?) {
		self.source = source
		self.inheritedEnvironmentPath = inheritedEnvironmentPath
		self.shell = shell
		self.home = home
	}

	public static func detect(
		from environment: [String: String],
		launchSourceEnvironmentKey: String? = nil,
		launchServicesEnvironmentValue: String = "launchservices"
	) -> ProcessLaunchContext {
		let source: ProcessLaunchSource
		if let launchSourceEnvironmentKey, environment[launchSourceEnvironmentKey] == launchServicesEnvironmentValue {
			source = .launchServices
		} else if isXcodeOrTestEnvironment(environment) {
			source = .xcode
		} else if isTerminalInheritedEnvironment(environment) {
			source = .terminalInherited
		} else {
			source = .unknown
		}

		return ProcessLaunchContext(
			source: source,
			inheritedEnvironmentPath: environment["PATH"],
			shell: environment["SHELL"],
			home: environment["HOME"]
		)
	}

	private static func isXcodeOrTestEnvironment(_ environment: [String: String]) -> Bool {
		let markerKeys = [
			"XCTestConfigurationFilePath",
			"XCTestSessionIdentifier",
			"XCODE_RUNNING_FOR_PREVIEWS",
			"__XCODE_BUILT_PRODUCTS_DIR_PATHS"
		]
		return markerKeys.contains { environment[$0] != nil }
	}

	private static func isTerminalInheritedEnvironment(_ environment: [String: String]) -> Bool {
		let terminalMarkerKeys = [
			"TERM",
			"TERM_PROGRAM",
			"SSH_TTY",
			"SSH_CONNECTION"
		]
		guard terminalMarkerKeys.contains(where: { environment[$0]?.isEmpty == false }) else {
			return false
		}
		return hasRichPath(environment["PATH"])
	}

	private static func hasRichPath(_ pathValue: String?) -> Bool {
		guard let pathValue, !pathValue.isEmpty else { return false }
		let components = pathValue.split(separator: ":").map(String.init)
		return components.contains { !standardSystemPaths.contains($0) }
	}

	private static let standardSystemPaths: Set<String> = [
		"/usr/bin",
		"/bin",
		"/usr/sbin",
		"/sbin"
	]
}
