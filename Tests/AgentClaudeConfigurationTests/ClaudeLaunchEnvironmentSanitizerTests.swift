import XCTest
@testable import AgentClaudeConfiguration

final class ClaudeLaunchEnvironmentSanitizerTests: XCTestCase {
	func testExplicitModeSetsOwnedKeyAndRemovesEveryOtherConflict() {
		let (overrides, removed) = ClaudeLaunchEnvironmentSanitizer.sanitize(
			mode: .anthropicAPIKey,
			appOwnedOverrides: ["ANTHROPIC_API_KEY": "sk-test"]
		)
		XCTAssertEqual(overrides["ANTHROPIC_API_KEY"], "sk-test")
		// The key we set is never also in the removal set (contradiction guard).
		XCTAssertFalse(removed.contains("ANTHROPIC_API_KEY"))
		// Everything else that could redirect auth is stripped.
		XCTAssertTrue(removed.contains("ANTHROPIC_AUTH_TOKEN"))
		XCTAssertTrue(removed.contains("ANTHROPIC_BASE_URL"))
		XCTAssertTrue(removed.contains("CLAUDE_CODE_USE_BEDROCK"))
	}

	func testExternalManagedPreservesUserAnthropicAuthButStripsOtherModeVars() {
		let (overrides, removed) = ClaudeLaunchEnvironmentSanitizer.sanitize(
			mode: .externalUserManagedClaudeCLI,
			appOwnedOverrides: [:]
		)
		XCTAssertTrue(overrides.isEmpty, "RepoPrompt injects nothing in user-managed mode")
		// User's own auth is preserved (subscription or their own key/proxy).
		XCTAssertFalse(removed.contains("ANTHROPIC_API_KEY"))
		XCTAssertFalse(removed.contains("ANTHROPIC_AUTH_TOKEN"))
		XCTAssertFalse(removed.contains("ANTHROPIC_BASE_URL"))
		// Cloud-mode toggles that belong to OTHER explicit modes are still stripped.
		XCTAssertTrue(removed.contains("CLAUDE_CODE_USE_BEDROCK"))
		XCTAssertTrue(removed.contains("CLAUDE_CODE_USE_VERTEX"))
	}
}
