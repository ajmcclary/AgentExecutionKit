import XCTest
import AgentClaudeConfiguration
import ClaudeRuntimeKit

final class ClaudeConfigurationPrivacyAndEmissionTests: XCTestCase {
    func testCompatibleEmissionRetainsTimeoutSlotsAndSubagentHints() {
        let value = ClaudeCompatibleEnvironmentPolicy.environment(baseURL: "https://host.test", authVariableName: "ANTHROPIC_AUTH_TOKEN", credential: "synthetic", timeoutMilliseconds: "3000000", slotMapping: .init(haiku: " small ", sonnet: " middle ", opus: " large "))
        XCTAssertEqual(value["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "small")
        XCTAssertEqual(value["ANTHROPIC_DEFAULT_SONNET_MODEL"], "middle")
        XCTAssertEqual(value["ANTHROPIC_DEFAULT_OPUS_MODEL"], "large")
        XCTAssertEqual(value["API_TIMEOUT_MS"], "3000000")
        XCTAssertEqual(value["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(value["CLAUDE_CODE_SUBAGENT_MODEL"], "small")
        XCTAssertEqual(ClaudeCompatibleEnvironmentPolicy.removedKeys(authVariableName: "ANTHROPIC_AUTH_TOKEN"), ["ANTHROPIC_API_KEY"])
    }
    func testNoModelEmissionDoesNotInventSlotsOrTimeout() {
        let value = ClaudeCompatibleEnvironmentPolicy.environment(baseURL: "host", authVariableName: "ANTHROPIC_API_KEY", credential: "synthetic", timeoutMilliseconds: nil, slotMapping: nil)
        XCTAssertEqual(Set(value.keys), ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"])
    }
    func testRedactedSnapshotsNeverCarryCredentialValues() {
        let env = ["ANTHROPIC_API_KEY": "secret-a", "ANTHROPIC_BASE_URL": "secret-b", "AWS_PROFILE": "secret-c", "CUSTOM_PASSWORD": "secret-d", "MAX_MCP_OUTPUT_TOKENS": "100", "PATH": "/host/bin"]
        let snapshot = ClaudeRedactedEnvironmentSnapshot(environment: env)
        XCTAssertEqual(snapshot.allKeys, Set(env.keys))
        XCTAssertEqual(snapshot.nonSecretValues, ["MAX_MCP_OUTPUT_TOKENS": "100", "PATH": "/host/bin"])
        for secret in ["secret-a", "secret-b", "secret-c", "secret-d"] { XCTAssertFalse(snapshot.description.contains(secret)) }
        XCTAssertTrue(snapshot.containsSecret("AWS_PROFILE"))
    }
    func testLegacyCredentialMetadataDecodesWithTheSameFieldNamesAndTokens() throws {
        let raw = Data(#"{"classIdentifier":"compatible_backend","providerLabel":"host"}"#.utf8)
        let metadata = try JSONDecoder().decode(ClaudeRunCredentialMetadata.self, from: raw)
        XCTAssertEqual(metadata, .init(mode: .compatibleBackend(label: "host")))
        XCTAssertEqual(Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]).keys), ["classIdentifier", "providerLabel"])
        let text = ClaudeCredentialRedactor.redactAuthenticationValues(in: "ANTHROPIC_API_KEY=synthetic OTHER=keep")
        XCTAssertEqual(text, "ANTHROPIC_API_KEY=<redacted> OTHER=keep")
    }
}
