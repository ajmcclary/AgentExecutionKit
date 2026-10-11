import Foundation

/// A policy rejection never silently discards session continuity. Only the
/// existing transient native-client startup failures may retry once, without resume.
public enum ClaudeNativeResumeRecovery {
	public static func shouldRetryFreshStartWithoutResume(
		after error: Error,
		existingSessionID: String?
	) -> Bool {
		guard
			let existingSessionID,
			!existingSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			let controllerError = error as? ClaudeNativeClientError
		else {
			return false
		}
		switch controllerError {
		// Any controller startup/handshake failure while attempting to resume an
		// existing Claude session is safer to recover by starting fresh and
		// injecting a handoff than by hard-failing the run. Fresh starts do not
		// take this path because they have no existing session ID.
		case .processNotRunning,
			.inputWriteFailed,
			.initializationFailed,
			.invalidControlResponse,
			.controlRequestTimedOut,
			// A resume whose initialize never got answered is the same class: the
			// attempt is already torn down and reaped by the time this is consulted,
			// so retrying fresh recovers the run instead of hard-failing it. A
			// wedged resume is in fact the case most likely to benefit.
			.initializationTimedOut:
			return true
		case .admissionRejected, .admissionRejectedPostInitialize, .admissionCycleGuardDiverged,
			.admissionAuthProvenanceDrift, .admissionEnvelopeMissing,
			// Item 10: a capability refusal is the same class of DELIBERATE decision.
			// Retrying fresh would re-derive a different launch-profile key and could
			// admit where this launch did not — silently converting "this session does
			// not offer that model/effort" into "we started a different session".
			.capabilityNotOffered:
			// Item 7: admission is a DELIBERATE policy decision, not a transient startup
			// failure. Note a fresh retry would NOT re-derive the same profile — dropping
			// `resumeRequested` changes the launch-profile key, so a fresh launch could
			// bind where the resume did not. We deliberately do NOT auto-retry, because
			// silently downgrading an admission-rejected RESUME into a fresh session would
			// discard the user's session continuity without their knowledge. Fail the run
			// and surface the rejection instead. Pinned by
			// `ClaudeAgentModeCoordinatorAdmissionRetryTests`.
			return false
		}
	}

    public struct Actions<Reference: Sendable> {
        public let startInitial: () async throws -> Reference
        public let stageHandoff: () -> Void
        public let shutdownInitial: () async -> Void
        public let discardInitial: () -> Void
        public let startFresh: () async throws -> Reference
        public init(startInitial: @escaping () async throws -> Reference, stageHandoff: @escaping () -> Void,
                    shutdownInitial: @escaping () async -> Void, discardInitial: @escaping () -> Void,
                    startFresh: @escaping () async throws -> Reference) {
            self.startInitial = startInitial; self.stageHandoff = stageHandoff
            self.shutdownInitial = shutdownInitial; self.discardInitial = discardInitial; self.startFresh = startFresh
        }
    }
    public static func start<Reference: Sendable>(existingSessionID: String?, actions: Actions<Reference>, isolation: isolated (any Actor)? = #isolation) async throws -> Reference {
        do { return try await actions.startInitial() }
        catch {
            guard shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID) else { throw error }
            actions.stageHandoff()
            await actions.shutdownInitial()
            actions.discardInitial()
            return try await actions.startFresh()
        }
    }
}
