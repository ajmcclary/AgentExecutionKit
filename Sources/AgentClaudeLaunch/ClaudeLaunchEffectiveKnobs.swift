import Foundation
import ClaudeRuntimeKit

/// Provider-specific effort vocabulary stays typed. Only its stable raw identity
/// participates in compatibility admission; no preference or catalog lookup.
public struct ClaudeLaunchEffectiveKnobs<Effort: RawRepresentable & Equatable & Sendable>: Equatable, Sendable where Effort.RawValue == String {
	public let existingSessionID: String?
	public let model: String?
	public let effortLevel: Effort?
	public let permissionMode: String
	public init(existingSessionID: String?, model: String?, effortLevel: Effort?, permissionMode: String) {
		self.existingSessionID = existingSessionID; self.model = model; self.effortLevel = effortLevel; self.permissionMode = permissionMode
	}
	public static func derive(from decision: ClaudeAdmissionDecision, requestedSessionID: String?, requestedModel: String?,
		requestedEffort: Effort?, requestedPermissionMode: String) -> Self {
		switch decision {
		case .admitUnrestricted:
			return .init(existingSessionID: requestedSessionID, model: requestedModel, effortLevel: requestedEffort, permissionMode: requestedPermissionMode)
		case .admitFull(let offered):
			return .init(existingSessionID: offered.resume ? requestedSessionID : nil,
				model: offers(offered.models, requestedModel) ? requestedModel : nil,
				effortLevel: offers(offered.effortLevels, requestedEffort?.rawValue) ? requestedEffort : nil, permissionMode: requestedPermissionMode)
		case .admitLimited(_, let offered, _):
			return .init(existingSessionID: offered.resume ? requestedSessionID : nil, model: nil, effortLevel: nil, permissionMode: nonBypass(requestedPermissionMode))
		case .reject:
			return .init(existingSessionID: nil, model: nil, effortLevel: nil, permissionMode: nonBypass(requestedPermissionMode))
		}
	}
	private static func offers(_ catalog: [String], _ requested: String?) -> Bool {
		guard let requested, !requested.isEmpty else { return false }; return catalog.contains(requested)
	}
	private static func nonBypass(_ mode: String) -> String { mode.caseInsensitiveCompare("bypassPermissions") == .orderedSame ? "default" : mode }
}
