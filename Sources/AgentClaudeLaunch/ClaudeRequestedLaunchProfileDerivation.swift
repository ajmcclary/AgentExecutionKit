import Foundation
import ClaudeRuntimeKit

/// Policy-independent requested profile construction. Host identity and path inputs are explicit.
public enum ClaudeRequestedLaunchProfileDerivation {
	public static func keyInput(
		commandName: String,
		resumeRequested: Bool,
		requestedModel: String?,
		defaultModelIdentifier: String,
		requestedEffortClass: ClaudeEffortClass,
		suppressesEffortSettings: Bool,
		permissionMode: String,
		backendClass: ClaudeBackendClass,
		authenticationModeClass: ClaudeAuthenticationModeClass,
		workingDirectoryClass: ClaudeWorkingDirectoryClass,
		mcpConfigPresent: Bool,
		mcpStrictMode: Bool,
		disallowedTools: Set<String>
	) -> ClaudeLaunchProfileKeyInput {
		ClaudeLaunchProfileKeyInput(
			commandNameClass: commandNameClass(commandName),
			resumeRequested: resumeRequested,
			modelRoute: modelRoute(requestedModel: requestedModel, defaultModelIdentifier: defaultModelIdentifier),
			effortClass: effortClass(requestedEffortClass, suppressed: suppressesEffortSettings),
			permissionModeClass: permissionModeClass(permissionMode),
			backendClass: backendClass,
			authenticationModeClass: authenticationModeClass,
			workingDirectoryClass: workingDirectoryClass,
			mcpConfigPresent: mcpConfigPresent,
			mcpStrictMode: mcpStrictMode,
			disallowedToolsDigest: ClaudeDisallowedToolsDigest(toolNames: disallowedTools))
	}

	// MARK: - Bounded mappings

	public static func commandNameClass(_ commandName: String) -> ClaudeCommandNameClass {
		let trimmed = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed == "claude" { return .defaultCommand }
		if trimmed.hasPrefix("/") { return .explicitPath }
		return .custom
	}

	/// The requested model route class — never the model string, and never the
	/// admission-adjusted effective model. `conservativeFallback` is admission-derived
	/// (set only when phase A downgrades the model), so it is not producible here.
	public static func modelRoute(requestedModel: String?, defaultModelIdentifier: String) -> ClaudeModelRoute {
		let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.isEmpty { return .defaultRoute }
		if trimmed.caseInsensitiveCompare(defaultModelIdentifier) == .orderedSame {
			return .defaultRoute
		}
		return .pinnedModel
	}

	public static func effortClass(_ level: ClaudeEffortClass, suppressed: Bool) -> ClaudeEffortClass {
		suppressed ? .defaultEffort : level
	}

	public static func permissionModeClass(_ raw: String) -> ClaudePermissionModeClass {
		switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "bypasspermissions": return .bypassPermissions
		case "acceptedits": return .acceptEdits
		case "plan": return .plan
		default: return .requireApproval
		}
	}

	/// Classify a working directory relative to the workspace root, never the raw
	/// path. A disposable temp directory is distinguished because the certified canary
	/// ran in one; a directory equal to (or under) the workspace root is
	/// `workspaceRoot`; anything else is `other`.
	public static func workingDirectoryClass(workingDirectory: String, workspaceRoot: String?, temporaryDirectory: String) -> ClaudeWorkingDirectoryClass {
		let dir = workingDirectory
		if let root = workspaceRoot, !root.isEmpty,
		   dir == root || dir.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
			return .workspaceRoot
		}
		let temp = temporaryDirectory
		if dir == temp || dir.hasPrefix(temp) || dir.hasPrefix("/private/tmp/") || dir.hasPrefix("/tmp/") {
			return .disposableOutsideRepo
		}
		return .other
	}
}
