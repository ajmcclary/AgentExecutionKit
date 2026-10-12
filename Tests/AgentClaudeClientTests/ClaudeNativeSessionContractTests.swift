import Foundation
import XCTest
import AgentClaudeClient
import AgentClaudeProtocol
import AgentClaudeCapabilities

final class ClaudeNativeSessionContractTests: XCTestCase {
    private let prefix = ["-p", "--verbose", "--output-format", "stream-json", "--input-format", "stream-json", "--permission-prompt-tool", "stdio"]
    private func args(_ session: String? = nil, mode: String = "acceptEdits", url: URL? = nil, strict: Bool = false, tools: [String] = []) -> [String] {
        ClaudeNativeSessionContract.arguments(existingSessionID: session, options: .init(permissionMode: mode, mcpConfigurationURL: url, strictMCP: strict, disallowedBuiltInTools: tools))
    }
    private func env(_ base: [String: String] = [:], search: Bool = false, config: [String: String] = [:], resolver: [String: String] = [:], removed: Set<String> = []) -> [String: String] {
        ClaudeNativeSessionContract.environment(base: base, toolSearchEnabled: search, configurationOverrides: config, resolverOverrides: resolver, resolverRemovedKeys: removed)
    }
    func testFreshEmptyAndRawResumeArgumentsRetainOrder() {
        XCTAssertEqual(args(), prefix); XCTAssertEqual(args(""), prefix)
        XCTAssertEqual(args(" session\n"), prefix + ["--resume", " session\n"])
        XCTAssertFalse(args().contains("--model")); XCTAssertFalse(args().contains("--system-prompt"))
    }
    func testPermissionBypassCaseAndWhitespaceMatchExistingContract() {
        XCTAssertEqual(args(mode: "BYPASSPERMISSIONS"), prefix + ["--allow-dangerously-skip-permissions"])
        for mode in ["plan", "auto", "default", "acceptEdits", " bypassPermissions "] { XCTAssertEqual(args(mode: mode), prefix) }
    }
    func testMCPStrictFlagRequiresConfigurationAndAllBranchesRetainOrder() {
        XCTAssertEqual(args(strict: true), prefix)
        let url = URL(fileURLWithPath: "/host/mcp config.json")
        XCTAssertEqual(args(url: url), prefix + ["--mcp-config", url.path])
        XCTAssertEqual(args("raw-session", mode: "bypassPermissions", url: url, strict: true, tools: ["WebFetch", "Bash"]), prefix + ["--resume", "raw-session", "--allow-dangerously-skip-permissions", "--mcp-config", url.path, "--strict-mcp-config", "--disallowedTools", "WebFetch,Bash"])
    }
    func testDisallowedToolsAreNotSortedDeduplicatedOrFiltered() {
        XCTAssertEqual(args(tools: ["Z", "A", "Z", ""]), prefix + ["--disallowedTools", "Z,A,Z,"])
        XCTAssertEqual(args(tools: []), prefix)
    }
    func testEnvironmentDefaultsAndEntrypointPreservation() {
        XCTAssertEqual(env(), ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts", "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "ENABLE_TOOL_SEARCH": "false"])
        XCTAssertEqual(env(["CLAUDE_CODE_ENTRYPOINT": ""])["CLAUDE_CODE_ENTRYPOINT"], "sdk-ts")
        XCTAssertEqual(env(["CLAUDE_CODE_ENTRYPOINT": "cli"])["CLAUDE_CODE_ENTRYPOINT"], "cli")
        XCTAssertEqual(env(["CLAUDE_CODE_ENTRYPOINT": " " ])["CLAUDE_CODE_ENTRYPOINT"], " ")
    }
    func testToolSearchOptInPreservesBaseRatherThanForcingTrue() {
        XCTAssertNil(env(search: true)["ENABLE_TOOL_SEARCH"])
        XCTAssertEqual(env(["ENABLE_TOOL_SEARCH": "custom"], search: true)["ENABLE_TOOL_SEARCH"], "custom")
        XCTAssertEqual(env(["ENABLE_TOOL_SEARCH": "true"])["ENABLE_TOOL_SEARCH"], "false")
    }
    func testConfigurationThenResolverOverrideNativeDefaults() {
        let result = env(["SOURCE": "base", "ENABLE_CLAUDEAI_MCP_SERVERS": "true"], config: ["SOURCE": "config", "ENABLE_TOOL_SEARCH": "config"], resolver: ["SOURCE": "resolver", "ENABLE_CLAUDEAI_MCP_SERVERS": "true"])
        XCTAssertEqual(result["SOURCE"], "resolver"); XCTAssertEqual(result["ENABLE_TOOL_SEARCH"], "config")
        XCTAssertEqual(result["ENABLE_CLAUDEAI_MCP_SERVERS"], "true")
    }
    func testFinalScrubWinsOverEveryOverrideIncludingSecretsAndLoaderVariables() {
        let result = env(["PATH": "/host/bin", "NODE_OPTIONS": "base", "DYLD_CUSTOM": "base"], config: ["NODE_OPTIONS": "config", "__XPC_DYLD_CUSTOM": "config", "SENTINEL_TOKEN": "fixture-config"], resolver: ["NODE_OPTIONS": "resolver", "DYLD_INSERT_LIBRARIES": "resolver", "SENTINEL_TOKEN": "fixture-resolver"], removed: ["SENTINEL_TOKEN"])
        XCTAssertEqual(result["PATH"], "/host/bin")
        for key in ["NODE_OPTIONS", "DYLD_CUSTOM", "__XPC_DYLD_CUSTOM", "DYLD_INSERT_LIBRARIES", "SENTINEL_TOKEN"] { XCTAssertNil(result[key]) }
    }
    func testEnvironmentInputIsNotMutatedAndHostNamespacesDoNotLeak() {
        let base = ["PATH": "/bin"]
        XCTAssertEqual(env(base, config: ["HOST": "A"])["HOST"], "A")
        XCTAssertNil(env(base)["HOST"]); XCTAssertEqual(base, ["PATH": "/bin"])
    }
    func testInitializeAbsentEmptyAndUnicodePromptRemainDistinct() throws {
        let absent = try ClaudeNativeSessionContract.initializeRequest(systemPromptOverride: nil).dictionary()
        XCTAssertEqual(absent.count, 1); XCTAssertEqual(absent["subtype"] as? String, "initialize")
        let empty = try ClaudeNativeSessionContract.initializeRequest(systemPromptOverride: "").dictionary()
        XCTAssertEqual(empty["systemPrompt"] as? String, ""); XCTAssertEqual(empty.count, 2)
        let prompt = "host\n🧪 \"quoted\""
        XCTAssertEqual(try ClaudeNativeSessionContract.initializeRequest(systemPromptOverride: prompt).dictionary()["systemPrompt"] as? String, prompt)
    }
    func testFlagSettingsSuppressInjectedDefaultIdentityAndEmptyRequests() throws {
        for model in [nil, "", " ", " DEFAULT "] as [String?] {
            XCTAssertNil(try ClaudeNativeSessionContract.flagSettingsRequest(model: model, effortLevel: nil, defaultModelIdentifier: "default"))
        }
        let custom = try ClaudeNativeSessionContract.flagSettingsRequest(model: "auto", effortLevel: nil, defaultModelIdentifier: "auto")
        XCTAssertNil(custom)
        let request = try XCTUnwrap(ClaudeNativeSessionContract.flagSettingsRequest(model: "default", effortLevel: nil, defaultModelIdentifier: "auto"))
        XCTAssertEqual(try request.dictionary()["settings"] as? [String: String], ["model": "default"])
    }
    func testFlagSettingsPreserveRawIdentifiersAndEffortStrings() throws {
        let request = try XCTUnwrap(ClaudeNativeSessionContract.flagSettingsRequest(model: "  raw-provider[1m]:max  ", effortLevel: "xhigh", defaultModelIdentifier: "default"))
        let payload = try request.dictionary()
        XCTAssertEqual(payload["subtype"] as? String, "apply_flag_settings")
        XCTAssertEqual(payload["settings"] as? [String: String], ["model": "raw-provider[1m]:max", "effortLevel": "xhigh"])
        let onlyEffort = try XCTUnwrap(ClaudeNativeSessionContract.flagSettingsRequest(model: nil, effortLevel: "low", defaultModelIdentifier: "default"))
        XCTAssertEqual(try onlyEffort.dictionary()["settings"] as? [String: String], ["effortLevel": "low"])
    }
    func testPermissionModeTrimsWithoutChangingSpellingAndEmptyOmitsRequest() throws {
        XCTAssertNil(try ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: " \n"))
        let request = try XCTUnwrap(ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: "  ACCEPTEDITS  "))
        XCTAssertEqual(try request.dictionary() as NSDictionary, ["subtype": "set_permission_mode", "mode": "ACCEPTEDITS"] as NSDictionary)
    }
}

@MainActor
final class ClaudeNativePermissionModeTests: XCTestCase {
    private enum Failure: Error, Equatable { case rpc }
    func testAbsentOrMalformedModeDoesNotSendOrClaimARoundTrip() async throws {
        for request in [nil, try ClaudeProtocolJSONObject(object: ["mode": 1])] as [ClaudeProtocolJSONObject?] {
            let result = try await ClaudeNativePermissionMode.apply(request: request, rpc: { _ in XCTFail(); throw Failure.rpc }, observe: { _ in XCTFail() })
            XCTAssertEqual(result, .notAttempted)
        }
    }
    func testConfirmedEchoPreservesResponseAndObservesOnlyAfterRPC() async throws {
        let request = try ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: " acceptEdits ")
        let response = try ClaudeProtocolJSONObject(object: ["mode": "ACCEPTEDITS", "future": ["value": true]])
        var order: [String] = []
        let result = try await ClaudeNativePermissionMode.apply(request: request, rpc: { value in XCTAssertEqual(value, request); order.append("rpc"); return response }, observe: { value in
            order.append("observe"); XCTAssertEqual(value.requestedMode, "acceptEdits"); XCTAssertEqual(value.response, response)
            XCTAssertEqual(value.roundTrip, .confirmed(mode: "ACCEPTEDITS"))
        })
        XCTAssertEqual(result, .confirmed(mode: "ACCEPTEDITS")); XCTAssertEqual(order, ["rpc", "observe"])
    }
    func testMissingOrMismatchedEchoNeverGrantsValidation() async throws {
        let request = try ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: "plan")
        for returned in [nil, "acceptEdits", " plan "] as [String?] {
            let result = try await ClaudeNativePermissionMode.apply(request: request, rpc: { _ in try .init(object: returned.map { ["mode": $0] } ?? [:]) }, observe: { _ in })
            XCTAssertFalse(result.satisfiesValidation)
            if let returned { XCTAssertEqual(result, .modeMismatch(requested: "plan", returned: returned)) }
            else { XCTAssertEqual(result, .succeededWithoutEcho(requested: "plan")) }
        }
    }
    func testRPCFailurePropagatesWithoutSuccessObservation() async throws {
        do { _ = try await ClaudeNativePermissionMode.apply(request: ClaudeNativeSessionContract.permissionModeRequest(effectivePermissionMode: "plan"), rpc: { _ in throw Failure.rpc }, observe: { _ in XCTFail() }); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .rpc) }
    }
}
