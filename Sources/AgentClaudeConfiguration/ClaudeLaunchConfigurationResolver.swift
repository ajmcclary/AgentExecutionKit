import Foundation

/// Host-isolated launch values. Secrets remain in the execution snapshot and never
/// in its redacted diagnostic representation or credential metadata.
public struct ClaudeLaunchEnvironment<BackendIdentity: Sendable>: Sendable {
    public typealias Backend = BackendIdentity
    public let effectiveModel: String?
    public let environmentOverrides: [String: String]
    public let removedEnvironmentKeys: Set<String>
    public let backend: BackendIdentity
    public let authenticationMode: ClaudeAuthenticationMode
    public let suppressesEffortSettings: Bool
    public init(effectiveModel: String?, environmentOverrides: [String: String], removedEnvironmentKeys: Set<String> = [],
                backend: BackendIdentity, authenticationMode: ClaudeAuthenticationMode = ClaudeAuthenticationModeSelection.select(variant: .standard, credentialState: .userManagedSession),
                suppressesEffortSettings: Bool = false) {
        self.effectiveModel = effectiveModel; self.environmentOverrides = environmentOverrides
        self.removedEnvironmentKeys = removedEnvironmentKeys; self.backend = backend
        self.authenticationMode = authenticationMode; self.suppressesEffortSettings = suppressesEffortSettings
    }
}

public enum ClaudeLaunchConfigurationFailure: Error, Equatable, Sendable {
    case invalidBackendConfiguration(label: String)
    case missingCredential(label: String)
    case externalUserManagedDenied
}

/// Immutable host configuration and deferred ports: validation/model selection
/// always precede credential reads. No preference or credential store is implicit.
public struct ClaudeCompatibleLaunchInput<Backend: Sendable>: Sendable {
    public let backend: Backend
    public let label: String
    public let isUsable: Bool
    public let suppressesEffortSettings: Bool
    public let additionalRemovedKeys: Set<String>
    public let resolveModel: @Sendable (String?) throws -> String?
    public let credential: @Sendable () async throws -> String?
    public let environment: @Sendable (String) -> [String: String]
    public init(backend: Backend, label: String, isUsable: Bool, suppressesEffortSettings: Bool,
                additionalRemovedKeys: Set<String>, resolveModel: @escaping @Sendable (String?) throws -> String?,
                credential: @escaping @Sendable () async throws -> String?,
                environment: @escaping @Sendable (String) -> [String: String]) {
        self.backend = backend; self.label = label; self.isUsable = isUsable
        self.suppressesEffortSettings = suppressesEffortSettings; self.additionalRemovedKeys = additionalRemovedKeys
        self.resolveModel = resolveModel; self.credential = credential; self.environment = environment
    }
}

public struct ClaudeLaunchConfigurationResolver<Backend: Sendable>: Sendable {
    private let standardBackend: Backend
    private let validateStandardModel: @Sendable (String?) throws -> String?
    private let standardCredential: @Sendable () async throws -> String?
    private let failClosedEnabled: @Sendable () -> Bool
    private let error: @Sendable (ClaudeLaunchConfigurationFailure) -> any Error
    public init(standardBackend: Backend, validateStandardModel: @escaping @Sendable (String?) throws -> String?,
                standardCredential: @escaping @Sendable () async throws -> String?, failClosedEnabled: @escaping @Sendable () -> Bool,
                error: @escaping @Sendable (ClaudeLaunchConfigurationFailure) -> any Error) {
        self.standardBackend = standardBackend; self.validateStandardModel = validateStandardModel
        self.standardCredential = standardCredential; self.failClosedEnabled = failClosedEnabled; self.error = error
    }
    public func resolveStandard(requestedModel: String?) async throws -> ClaudeLaunchEnvironment<Backend> {
        let model = try validateStandardModel(requestedModel)
        let credential = try await standardCredential()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOwnedKey = !(credential ?? "").isEmpty
        let mode = ClaudeAuthenticationModeSelection.select(
            variant: .standard, credentialState: hasOwnedKey ? .appOwnedAnthropicKey : .userManagedSession)
        var owned: [String: String] = [:]
        if hasOwnedKey, let credential { owned["ANTHROPIC_API_KEY"] = credential }
        if failClosedEnabled(), !mode.isExplicitHostControlled { throw error(.externalUserManagedDenied) }
        let sanitized = ClaudeLaunchEnvironmentSanitizer.sanitize(mode: mode, appOwnedOverrides: owned)
        return ClaudeLaunchEnvironment(effectiveModel: model, environmentOverrides: sanitized.overrides,
            removedEnvironmentKeys: sanitized.removedKeys, backend: standardBackend, authenticationMode: mode)
    }
    public func resolveCompatible(_ input: ClaudeCompatibleLaunchInput<Backend>, requestedModel: String?) async throws -> ClaudeLaunchEnvironment<Backend> {
        guard input.isUsable else { throw error(.invalidBackendConfiguration(label: input.label)) }
        let model = try input.resolveModel(requestedModel)
        guard let credential = try await input.credential()?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty
        else { throw error(.missingCredential(label: input.label)) }
        let mode = ClaudeAuthenticationModeSelection.select(variant: .compatible, credentialState: .compatibleBackend(label: input.label))
        let owned = input.environment(credential)
        let sanitized = ClaudeLaunchEnvironmentSanitizer.sanitize(mode: mode, appOwnedOverrides: owned)
        let removed = sanitized.removedKeys.union(input.additionalRemovedKeys).subtracting(owned.keys)
        return ClaudeLaunchEnvironment(effectiveModel: model, environmentOverrides: sanitized.overrides,
            removedEnvironmentKeys: removed, backend: input.backend, authenticationMode: mode,
            suppressesEffortSettings: input.suppressesEffortSettings)
    }
}
