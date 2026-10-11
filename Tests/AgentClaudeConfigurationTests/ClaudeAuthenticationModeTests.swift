import XCTest
@testable import AgentClaudeConfiguration

final class ClaudeAuthenticationModeTests: XCTestCase {
	func testExplicitControlledExcludesExternalManaged() {
		XCTAssertTrue(ClaudeAuthenticationMode.anthropicAPIKey.isExplicitHostControlled)
		XCTAssertTrue(ClaudeAuthenticationMode.compatibleBackend(label: "GLM").isExplicitHostControlled)
		XCTAssertFalse(ClaudeAuthenticationMode.externalUserManagedClaudeCLI.isExplicitHostControlled)
	}

	func testPersistedClassIdentifierIsStableAndSecretFree() {
		XCTAssertEqual(ClaudeAuthenticationMode.anthropicAPIKey.persistedClassIdentifier, "anthropic_api_key")
		XCTAssertEqual(ClaudeAuthenticationMode.externalUserManagedClaudeCLI.persistedClassIdentifier, "external_user_managed_cli")
		XCTAssertEqual(ClaudeAuthenticationMode.compatibleBackend(label: "GLM").persistedClassIdentifier, "compatible_backend")
	}

	func testProviderLabelOnlyForLabeledModes() {
		XCTAssertEqual(ClaudeAuthenticationMode.compatibleBackend(label: "GLM").providerLabel, "GLM")
		XCTAssertNil(ClaudeAuthenticationMode.anthropicAPIKey.providerLabel)
	}
}
