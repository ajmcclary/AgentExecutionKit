import XCTest
import AgentClaudeLaunch
import ClaudeRuntimeKit

final class ClaudeRequestedLaunchProfileDerivationTests: XCTestCase {
    func testCanonicalRequestedProfilePreservesCertifiedGolden() {
        let input = ClaudeRequestedLaunchProfileDerivation.keyInput(
            commandName: "/host/claude", resumeRequested: false, requestedModel: nil,
            defaultModelIdentifier: "host-default", requestedEffortClass: .defaultEffort,
            suppressesEffortSettings: false, permissionMode: "default", backendClass: .standardClaude,
            authenticationModeClass: .anthropicAPIKey, workingDirectoryClass: .disposableOutsideRepo,
            mcpConfigPresent: true, mcpStrictMode: true, disallowedTools: [])
        XCTAssertEqual(ClaudeLaunchProfileKey(input: input).digest.value,
            "e831b109495ed27b600b61725fcc7fea03ce4d3dafe4654b9653035897feb0dc")
    }
    func testHostDefaultModelIdentifierAndPermissionNormalizationAreExplicit() {
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.modelRoute(requestedModel: " HOST-DEFAULT ", defaultModelIdentifier: "host-default"), .defaultRoute)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.modelRoute(requestedModel: "default", defaultModelIdentifier: "host-default"), .pinnedModel)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.modelRoute(requestedModel: nil, defaultModelIdentifier: "host-default"), .defaultRoute)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.commandNameClass(" claude "), .defaultCommand)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.commandNameClass("/host/claude"), .explicitPath)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.commandNameClass("host-claude"), .custom)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.permissionModeClass(" BYPASSPERMISSIONS "), .bypassPermissions)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.permissionModeClass(" acceptEdits "), .acceptEdits)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.permissionModeClass("plan"), .plan)
        XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.permissionModeClass("future"), .requireApproval)
    }
    func testSuppressionAndPathPrecedencePreserveExistingRules() {
        for level in [ClaudeEffortClass.defaultEffort, .reduced, .elevated] {
            XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.effortClass(level, suppressed: true), .defaultEffort)
            XCTAssertEqual(ClaudeRequestedLaunchProfileDerivation.effortClass(level, suppressed: false), level)
        }
        let classify = ClaudeRequestedLaunchProfileDerivation.workingDirectoryClass
        XCTAssertEqual(classify("/host/temp/repo/file", "/host/temp/repo", "/host/temp/"), .workspaceRoot)
        XCTAssertEqual(classify("/repo-other", "/repo", "/host/temp/"), .other)
        XCTAssertEqual(classify("/repo/file", "/repo/", "/host/temp/"), .workspaceRoot)
        XCTAssertEqual(classify("/host/temp/file", nil, "/host/temp/"), .disposableOutsideRepo)
        XCTAssertEqual(classify("/private/tmp/file", nil, "/host/temp/"), .disposableOutsideRepo)
        XCTAssertEqual(classify("/tmp/file", nil, "/host/temp/"), .disposableOutsideRepo)
        XCTAssertEqual(classify("/other", nil, "/host/temp/"), .other)
    }
    func testTypedConfigurationAxesAndToolsReachTheKeyWithoutPolicySubstitution() {
        let input = ClaudeRequestedLaunchProfileDerivation.keyInput(
            commandName: "host-command", resumeRequested: true, requestedModel: "pinned",
            defaultModelIdentifier: "host-default", requestedEffortClass: .elevated,
            suppressesEffortSettings: false, permissionMode: "acceptEdits", backendClass: .customCompatible,
            authenticationModeClass: .compatibleBackendCredential, workingDirectoryClass: .workspaceRoot,
            mcpConfigPresent: true, mcpStrictMode: false, disallowedTools: ["Write", "Edit"])
        XCTAssertEqual(input.commandNameClass, .custom); XCTAssertTrue(input.resumeRequested)
        XCTAssertEqual(input.modelRoute, .pinnedModel); XCTAssertEqual(input.effortClass, .elevated)
        XCTAssertEqual(input.permissionModeClass, .acceptEdits); XCTAssertEqual(input.backendClass, .customCompatible)
        XCTAssertEqual(input.authenticationModeClass, .compatibleBackendCredential)
        XCTAssertEqual(input.workingDirectoryClass, .workspaceRoot); XCTAssertTrue(input.mcpConfigPresent)
        XCTAssertFalse(input.mcpStrictMode)
        XCTAssertEqual(input.disallowedToolsDigest, ClaudeDisallowedToolsDigest(toolNames: ["Edit", "Write"]))
    }
}
