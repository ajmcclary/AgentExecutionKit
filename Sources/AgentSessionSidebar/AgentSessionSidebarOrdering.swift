import Foundation
import AgentRuntimeKit

public enum AgentSessionSidebarOrdering {
	public static func shouldPreferSidebarEntry(_ lhs: AgentSessionIndexEntry, over rhs: AgentSessionIndexEntry) -> Bool {
		if lhs.lastUserMessageAt != rhs.lastUserMessageAt {
			return shouldListBefore(
				lhsID: lhs.id,
				lhsDate: lhs.lastUserMessageAt,
				rhsID: rhs.id,
				rhsDate: rhs.lastUserMessageAt
			)
		}
		if lhs.savedAt != rhs.savedAt {
			return lhs.savedAt > rhs.savedAt
		}
		return lhs.id.uuidString < rhs.id.uuidString
	}

	public static func sidebarActivityDate(for entry: AgentSessionIndexEntry) -> Date {
		sidebarActivityDate(lastUserMessageAt: entry.lastUserMessageAt, savedAt: entry.savedAt)
	}

	public static func sidebarActivityDate(lastUserMessageAt: Date?, savedAt: Date) -> Date {
		lastUserMessageAt ?? savedAt
	}

	private static func shouldListBefore(
		lhsID: UUID,
		lhsDate: Date?,
		rhsID: UUID,
		rhsDate: Date?
	) -> Bool {
		switch (lhsDate, rhsDate) {
		case let (lhsDate?, rhsDate?):
			if lhsDate != rhsDate {
				return lhsDate > rhsDate
			}
		case (.some, .none):
			return true
		case (.none, .some):
			return false
		case (.none, .none):
			break
		}
		return lhsID.uuidString < rhsID.uuidString
	}}
