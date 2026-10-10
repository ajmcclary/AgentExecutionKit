import Foundation
import AIClientKit
import AgentRuntimeKit

public enum ACPHeadlessRuntimeEvent: Sendable {
	case stream(AIStreamResult)
	case approvalRequested(AgentApprovalRequest)
	case approvalCancelled(AgentApprovalRequestID)
	/// A permission request was RESOLVED by a decision the controller sent on the wire
	/// (eleventh round, finding 6). Distinct from `approvalCancelled` (the request went
	/// away without our decision): this is the authoritative signal that a decision — a
	/// manual UI response OR an automatic profile/session-mode activation — was submitted,
	/// so any UI still showing that exact request must clear it and resume run state.
	case approvalResolved(AgentApprovalRequestID)
	case terminal(state: AgentSessionRunState, errorText: String?)
}

