import XCTest
import Synchronization
import AgentClaudeConfiguration
import ClaudeRuntimeKit

final class ClaudeLaunchConfigurationResolverTests: XCTestCase {
    private final class Calls: Sendable {
        private let values = Mutex<[String]>([])
        func add(_ value: String) { values.withLock { $0.append(value) } }
        var all: [String] { values.withLock { $0 } }
    }
    private enum Failure: Error, Equatable { case model, key }
    private func resolver(_ calls: Calls, key: String? = nil, closed: Bool = false,
                          validate: @escaping @Sendable (String?) throws -> String? = { $0 }) -> ClaudeLaunchConfigurationResolver<String> {
        .init(standardBackend: "host-standard", validateStandardModel: { raw in
            calls.add("model"); return try validate(raw)
        }, standardCredential: { calls.add("key"); return key }, failClosedEnabled: { calls.add("policy"); return closed }, error: { $0 })
    }
    func testStandardOwnedCredentialOrderingAndIsolation() async throws {
        let calls = Calls()
        let value = try await resolver(calls, key: "  synthetic-key ").resolveStandard(requestedModel: "raw-model")
        XCTAssertEqual(calls.all, ["model", "key", "policy"])
        XCTAssertEqual(value.backend, "host-standard"); XCTAssertEqual(value.effectiveModel, "raw-model")
        XCTAssertEqual(value.authenticationMode, .anthropicAPIKey)
        XCTAssertEqual(value.environmentOverrides["ANTHROPIC_API_KEY"], "synthetic-key")
        XCTAssertFalse(value.removedEnvironmentKeys.contains("ANTHROPIC_API_KEY"))
        XCTAssertTrue(value.removedEnvironmentKeys.contains("ANTHROPIC_AUTH_TOKEN"))
    }
    func testInvalidStandardModelNeverReadsCredentialOrPolicy() async {
        let calls = Calls()
        do { _ = try await resolver(calls, validate: { _ in throw Failure.model }).resolveStandard(requestedModel: "wrong"); XCTFail() }
        catch { XCTAssertEqual(error as? Failure, .model) }
        XCTAssertEqual(calls.all, ["model"])
    }
    func testExternalCredentialsArePreservedAndNotInjected() async throws {
        let value = try await resolver(Calls(), key: "  ").resolveStandard(requestedModel: nil)
        XCTAssertEqual(value.authenticationMode, .externalUserManagedClaudeCLI)
        XCTAssertTrue(value.environmentOverrides.isEmpty)
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"] { XCTAssertFalse(value.removedEnvironmentKeys.contains(key)) }
        XCTAssertTrue(value.removedEnvironmentKeys.contains("CLAUDE_CODE_USE_BEDROCK"))
    }
    func testFailClosedRefusesOnlyExternalManagedStandardMode() async throws {
        do { _ = try await resolver(Calls(), closed: true).resolveStandard(requestedModel: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeLaunchConfigurationFailure, .externalUserManagedDenied) }
        let value = try await resolver(Calls(), key: "owned", closed: true).resolveStandard(requestedModel: nil)
        XCTAssertEqual(value.authenticationMode, .anthropicAPIKey)
    }
    private func input(_ calls: Calls, usable: Bool = true, key: String? = "secret", modelFails: Bool = false) -> ClaudeCompatibleLaunchInput<String> {
        .init(backend: "host-record", label: "Host backend", isUsable: usable, suppressesEffortSettings: true,
              additionalRemovedKeys: ["HOST_REMOVE", "ANTHROPIC_AUTH_TOKEN"], resolveModel: { _ in
                calls.add("model"); if modelFails { throw Failure.model }; return nil
              }, credential: { calls.add("key"); return key }, environment: { credential in
                calls.add("environment"); return ["ANTHROPIC_AUTH_TOKEN": credential, "HOST_KEEP": "keep"]
              })
    }
    func testCompatibleConfigurationAndModelFailuresShortCircuitBeforeCredentials() async {
        for (usable, modelFails) in [(false, false), (true, true)] {
            let calls = Calls()
            do { _ = try await resolver(calls).resolveCompatible(input(calls, usable: usable, modelFails: modelFails), requestedModel: "requested"); XCTFail() }
            catch {
                if usable { XCTAssertEqual(error as? Failure, .model) }
                else { XCTAssertEqual(error as? ClaudeLaunchConfigurationFailure, .invalidBackendConfiguration(label: "Host backend")) }
            }
            XCTAssertEqual(calls.all, usable ? ["model"] : [])
        }
    }
    func testMissingCompatibleKeyDoesNotEmitEnvironmentOrFallbackToStandardAuth() async {
        let calls = Calls()
        do { _ = try await resolver(calls, key: "standard-key").resolveCompatible(input(calls, key: "  "), requestedModel: nil); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeLaunchConfigurationFailure, .missingCredential(label: "Host backend")) }
        XCTAssertEqual(calls.all, ["model", "key"])
    }
    func testCompatibleMergesRemovalPoliciesWithoutRemovingOwnedKeys() async throws {
        let calls = Calls()
        let value = try await resolver(calls, closed: true).resolveCompatible(input(calls, key: " token "), requestedModel: nil)
        XCTAssertEqual(calls.all, ["model", "key", "environment"])
        XCTAssertNil(value.effectiveModel); XCTAssertTrue(value.suppressesEffortSettings)
        XCTAssertEqual(value.backend, "host-record")
        XCTAssertEqual(value.authenticationMode, .compatibleBackend(label: "Host backend"))
        XCTAssertEqual(value.environmentOverrides["ANTHROPIC_AUTH_TOKEN"], "token")
        XCTAssertTrue(value.removedEnvironmentKeys.contains("HOST_REMOVE"))
        XCTAssertFalse(value.removedEnvironmentKeys.contains("ANTHROPIC_AUTH_TOKEN"))
    }
    func testCredentialErrorsAndCancellationPropagateWithoutEmission() async {
        let calls = Calls()
        let value = ClaudeLaunchConfigurationResolver(standardBackend: "host", validateStandardModel: { _ in nil },
            standardCredential: { throw CancellationError() }, failClosedEnabled: { calls.add("policy"); return false }, error: { $0 })
        do { _ = try await value.resolveStandard(requestedModel: nil); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.all, [])
        let bad = ClaudeCompatibleLaunchInput(backend: "host", label: "host", isUsable: true, suppressesEffortSettings: false,
            additionalRemovedKeys: [], resolveModel: { _ in nil }, credential: { throw Failure.key }, environment: { _ in calls.add("emit"); return [:] })
        do { _ = try await resolver(calls).resolveCompatible(bad, requestedModel: nil); XCTFail() } catch { XCTAssertEqual(error as? Failure, .key) }
        XCTAssertEqual(calls.all, [])
    }
    func testModeEnumerationUsesTheSameProducerAndKeepsUnreachableCloudModesExcluded() {
        for variant in [ClaudeAuthenticationModeSelection.Variant.standard, .compatible] {
            let states = ClaudeAuthenticationModeSelection.reachableStates(for: variant, credentialLabel: "host")
            XCTAssertEqual(ClaudeAuthenticationModeSelection.reachableModes(for: variant, credentialLabel: "host"), states.map { ClaudeAuthenticationModeSelection.select(variant: variant, credentialState: $0) })
        }
        XCTAssertEqual(ClaudeAuthenticationModeSelection.reachableModes(for: .standard, credentialLabel: "host"), [.anthropicAPIKey, .externalUserManagedClaudeCLI])
        XCTAssertEqual(ClaudeAuthenticationModeSelection.select(variant: .standard, credentialState: .compatibleBackend(label: "wrong")), .externalUserManagedClaudeCLI)
        XCTAssertEqual(ClaudeAuthenticationModeSelection.select(variant: .compatible, credentialState: .appOwnedAnthropicKey), .compatibleBackend(label: ""))
    }
}
