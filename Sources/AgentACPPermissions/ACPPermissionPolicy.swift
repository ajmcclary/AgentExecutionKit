import Foundation
import AgentRuntimeKit

public struct ACPPermissionOption: Sendable, Equatable {
	public let optionID: String
	public let kind: String
	public init(optionID: String, kind: String) { self.optionID = optionID; self.kind = kind }
}
public enum ACPPermissionPreference: Sendable { case optionID(String), kind(String) }

/// Explicit host policy. Automatic approval is disabled unless the host supplies it.
public struct ACPPermissionPolicy: Sendable {
	public let allowOnce: [ACPPermissionPreference]
	public let allowSession: [ACPPermissionPreference]
	public let reject: [ACPPermissionPreference]
	public let sessionAffordance: [ACPPermissionPreference]
	public let automatic: [ACPPermissionPreference]?
	public init(allowOnce: [ACPPermissionPreference], allowSession: [ACPPermissionPreference],
		reject: [ACPPermissionPreference], sessionAffordance: [ACPPermissionPreference],
		automatic: [ACPPermissionPreference]? = nil) {
		self.allowOnce = allowOnce; self.allowSession = allowSession; self.reject = reject
		self.sessionAffordance = sessionAffordance; self.automatic = automatic
	}
	public static func optionID(for options: [ACPPermissionOption], preferences: [ACPPermissionPreference]) -> String? {
		for preference in preferences {
			switch preference {
			case .optionID(let raw):
				if let value = normalized(raw), let option = options.first(where: { normalized($0.optionID) == value }) { return option.optionID }
			case .kind(let raw):
				if let value = normalized(raw), let option = options.first(where: { normalized($0.kind) == value }) { return option.optionID }
			}
		}
		return nil
	}
	public func optionID(for options: [ACPPermissionOption], decision: AgentApprovalDecision) -> String? {
		switch decision {
		case .accept: return Self.optionID(for: options, preferences: allowOnce)
		case .acceptForSession, .acceptWithExecpolicyAmendment: return Self.optionID(for: options, preferences: allowSession)
		case .decline: return Self.optionID(for: options, preferences: reject)
		case .cancel: return nil
		}
	}
	private static func normalized(_ value: String) -> String? {
		let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		return normalized.isEmpty ? nil : normalized
	}
}
