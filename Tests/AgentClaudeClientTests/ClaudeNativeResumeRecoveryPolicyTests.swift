import XCTest
import AgentClaudeClient
import ClaudeRuntimeKit

// Item 7, correction 2: the resume-retry policy for an admission rejection.
//
// Dropping `resumeRequested` changes the launch-profile key, so a fresh launch
// COULD bind where a resume did not — a fresh retry is not a no-op. We deliberately
// do NOT auto-retry, because silently downgrading an admission-rejected resume into
// a fresh session would discard the user's session continuity without their
// knowledge. This pins that policy: admission rejections are terminal for the run;
// ordinary startup failures still recover by fresh retry.

@MainActor
final class ClaudeNativeResumeRecoveryPolicyTests: XCTestCase {

    private struct Policy {
        func test_shouldRetryFreshStartWithoutResume(after error: any Error, existingSessionID: String?) -> Bool {
            ClaudeNativeResumeRecovery.shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID)
        }
    }
    private func coordinator() -> Policy { Policy() }

	private let sessionID = "user-owned-session"

	func testAdmissionRejectionOnResumeIsNotRetriedFresh() {
		let c = coordinator()
		let rejected = ClaudeNativeClientError
			.admissionRejected(.behaviorUnavailable)
		XCTAssertFalse(
			c.test_shouldRetryFreshStartWithoutResume(after: rejected, existingSessionID: sessionID),
			"an admission rejection must NOT silently downgrade a resume into a fresh session")
	}

	func testCycleGuardDivergenceOnResumeIsNotRetriedFresh() {
		let c = coordinator()
		let diverged = ClaudeNativeClientError.admissionCycleGuardDiverged
		XCTAssertFalse(
			c.test_shouldRetryFreshStartWithoutResume(after: diverged, existingSessionID: sessionID))
	}

	/// Phase B rejects AFTER the child is running, so it arrives through a different
	/// error case than the pre-spawn rejection — and must be equally terminal. A
	/// fresh retry here would spawn a SECOND child for a runtime admission has
	/// already refused.
	func testPostInitializeAdmissionRejectionOnResumeIsNotRetriedFresh() {
		let c = coordinator()
		let rejected = ClaudeNativeClientError
			.admissionRejectedPostInitialize(.validationFailed(.permissionModeRoundTripFailed))
		XCTAssertFalse(
			c.test_shouldRetryFreshStartWithoutResume(after: rejected, existingSessionID: sessionID),
			"a phase-B admission rejection is terminal for the run, like a phase-A one")
	}

	func testAuthProvenanceDriftAndMissingEnvelopeAreTerminal() {
		let c = coordinator()
		for error in [
			ClaudeNativeClientError.admissionAuthProvenanceDrift,
			ClaudeNativeClientError.admissionEnvelopeMissing,
		] {
			XCTAssertFalse(
				c.test_shouldRetryFreshStartWithoutResume(after: error, existingSessionID: sessionID),
				"\(error) is a fail-closed admission outcome, never a transient startup failure")
		}
	}

	func testOrdinaryStartupFailureOnResumeStillRetriesFresh() {
		// The contrast case: a transient startup failure during a resume DOES recover by
		// starting fresh — only admission decisions are terminal.
		let c = coordinator()
		let transient = ClaudeNativeClientError
			.initializationFailed("reader setup failed")
		XCTAssertTrue(
			c.test_shouldRetryFreshStartWithoutResume(after: transient, existingSessionID: sessionID))
	}

	func testFreshStart_noExistingSession_neverRetries() {
		// A fresh start has no session ID, so the retry path never applies regardless.
		let c = coordinator()
		let rejected = ClaudeNativeClientError
			.admissionRejected(.behaviorUnavailable)
		XCTAssertFalse(c.test_shouldRetryFreshStartWithoutResume(after: rejected, existingSessionID: nil))
	}
}
