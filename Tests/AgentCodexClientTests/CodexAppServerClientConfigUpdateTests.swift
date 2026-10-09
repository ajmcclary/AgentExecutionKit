import XCTest
@testable import AgentCodexClient
import ProcessKit
import CodexRuntimeKit

/// Pins that the targeted `Config` update paths replace only their intended
/// field. Both `updateWorkingDirectory` and `updateProcessFeaturePolicy`
/// previously rebuilt `Config` through the memberwise initializer while
/// omitting `environmentOverrides` and `backoffPolicy`, silently resetting
/// both to their defaults.
final class CodexAppServerClientConfigUpdateTests: XCTestCase {
	private static let nonDefaultConfig = CodexAppServerClient.Config(
		commandName: "codex-alt",
		additionalPathHints: ["/opt/custom/bin"],
		enableDebugLogging: true,
		requestTimeout: 42,
		workingDirectory: "/tmp/original",
		processFeaturePolicy: .enabledForGoals,
		environmentOverrides: ["OPENAI_API_KEY": "sk-preserved"],
		backoffPolicy: CodexBackoffPolicy(maxRetries: 7, baseDelay: 1.5, multiplier: 3.0, maxDelay: 30.0),
		experimentalRequirements: [.memoryMode]
	)

	private func assertMatchesNonDefaultConfig(
		_ config: CodexAppServerClient.Config,
		exceptWorkingDirectory workingDirectory: String?? = nil,
		exceptProcessFeaturePolicy featurePolicy: CodexProcessFeaturePolicy? = nil,
		exceptExperimentalRequirements experimentalRequirements: Set<CodexExperimentalRequirement>? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let expected = Self.nonDefaultConfig
		XCTAssertEqual(config.commandName, expected.commandName, file: file, line: line)
		XCTAssertEqual(config.additionalPathHints, expected.additionalPathHints, file: file, line: line)
		XCTAssertEqual(config.enableDebugLogging, expected.enableDebugLogging, file: file, line: line)
		XCTAssertEqual(config.requestTimeout, expected.requestTimeout, file: file, line: line)
		XCTAssertEqual(
			config.workingDirectory,
			workingDirectory ?? expected.workingDirectory,
			file: file, line: line
		)
		XCTAssertEqual(
			config.processFeaturePolicy,
			featurePolicy ?? expected.processFeaturePolicy,
			file: file, line: line
		)
		XCTAssertEqual(config.environmentOverrides, expected.environmentOverrides, file: file, line: line)
		XCTAssertEqual(config.backoffPolicy, expected.backoffPolicy, file: file, line: line)
		XCTAssertEqual(
			config.experimentalRequirements,
			experimentalRequirements ?? expected.experimentalRequirements,
			file: file, line: line
		)
	}

	// MARK: Config replacement helpers

	func test_replacingWorkingDirectory_changesOnlyWorkingDirectory() {
		let replaced = Self.nonDefaultConfig.replacingWorkingDirectory("/tmp/replaced")
		assertMatchesNonDefaultConfig(replaced, exceptWorkingDirectory: "/tmp/replaced")
	}

	func test_replacingWorkingDirectory_acceptsNil() {
		let replaced = Self.nonDefaultConfig.replacingWorkingDirectory(nil)
		assertMatchesNonDefaultConfig(replaced, exceptWorkingDirectory: .some(nil))
	}

	func test_replacingProcessFeaturePolicy_changesOnlyFeaturePolicy() {
		let replaced = Self.nonDefaultConfig.replacingProcessFeaturePolicy(.enabledForComputerUse)
		assertMatchesNonDefaultConfig(replaced, exceptProcessFeaturePolicy: .enabledForComputerUse)
	}

	func test_replacingExperimentalRequirements_changesOnlyRequirements() {
		let replaced = Self.nonDefaultConfig.replacingExperimentalRequirements([.legacyThreadResumePath])
		assertMatchesNonDefaultConfig(replaced, exceptExperimentalRequirements: [.legacyThreadResumePath])
	}

	// MARK: Client update methods

	func test_updateWorkingDirectory_preservesAllOtherConfigFields() async {
		let client = CodexAppServerClient()
		await client.updateConfig(Self.nonDefaultConfig)

		await client.updateWorkingDirectory("/tmp/updated")

		let config = await client.config
		assertMatchesNonDefaultConfig(config, exceptWorkingDirectory: "/tmp/updated")
	}

	func test_updateWorkingDirectory_normalizesWhitespaceToNil_andPreservesOtherFields() async {
		let client = CodexAppServerClient()
		await client.updateConfig(Self.nonDefaultConfig)

		await client.updateWorkingDirectory("   ")

		let config = await client.config
		assertMatchesNonDefaultConfig(config, exceptWorkingDirectory: .some(nil))
	}

	func test_updateProcessFeaturePolicy_preservesAllOtherConfigFields() async {
		let client = CodexAppServerClient()
		await client.updateConfig(Self.nonDefaultConfig)

		await client.updateProcessFeaturePolicy(.enabledForComputerUse)

		let config = await client.config
		assertMatchesNonDefaultConfig(config, exceptProcessFeaturePolicy: .enabledForComputerUse)
	}

	func test_updateExperimentalRequirements_preservesAllOtherConfigFields() async {
		let client = CodexAppServerClient()
		await client.updateConfig(Self.nonDefaultConfig)

		await client.updateExperimentalRequirements([], reason: "test: back to stable")

		let config = await client.config
		assertMatchesNonDefaultConfig(config, exceptExperimentalRequirements: [])
	}
}
