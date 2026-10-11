import Foundation
import ClaudeRuntimeKit

public enum ClaudeNativeClientError: Error, LocalizedError, Equatable, Sendable {
	case processNotRunning
	case initializationFailed(String)
	case invalidControlResponse(String)
	case inputWriteFailed(String)
	case controlRequestTimedOut(requestID: String)
	case initializationTimedOut(seconds: TimeInterval)
	/// Item 7, phase A: admission rejected the launch before spawn (stage ≥ 1).
	case admissionRejected(ClaudeAdmissionRejectReason)
	/// Item 7, phase B: the FINAL post-initialize classification rejected. The
	/// child is already running, so this throw propagates through
	/// `startOrResume`'s existing catch, which tears the transport down (§4.7).
	/// Deliberately distinct from `.admissionRejected` so telemetry and the retry
	/// policy can tell a pre-spawn refusal from a post-initialize one.
	case admissionRejectedPostInitialize(ClaudeAdmissionRejectReason)
	/// Item 7, §4.2 cycle guard: the final-environment resolution diverged from the
	/// policy-independent one, so a policy-dependent value influenced resolution.
	case admissionCycleGuardDiverged
	/// Item 7 P1: backend/auth changed between the policy-independent resolution and
	/// the effective one, so identity/key/child could bind under different auth
	/// classes. Fail closed rather than launch under drifted provenance.
	case admissionAuthProvenanceDrift
	/// Item 7 P1: a spawned child had no admission envelope where §5.2 requires one
	/// (the effective permission mode). Fail closed rather than send the requested
	/// (possibly bypass) mode.
	case admissionEnvelopeMissing
	/// Item 10: a model/effort update was refused because this session's capability
	/// projection does not offer it (stage >= 2 only; see §5.3/§7.2).
	case capabilityNotOffered(String)

	/// Whether this is a capability refusal, so a caller can act on it without
	/// pattern-matching the case (and without an `if case` in a `catch` clause,
	/// which Swift does not allow).
	public var isCapabilityRefusal: Bool {
		if case .capabilityNotOffered = self { return true }
		return false
	}

	public var errorDescription: String? {
		switch self {
		case .processNotRunning:
			return "Claude process is not running."
		case .initializationFailed(let message):
			return "Claude initialization failed: \(message)"
		case .invalidControlResponse(let message):
			return "Claude control response failed: \(message)"
		case .inputWriteFailed(let message):
			return "Failed writing to Claude process stdin: \(message)"
		case .controlRequestTimedOut(let requestID):
			return "Claude control request timed out: \(requestID)"
		case .initializationTimedOut(let seconds):
			return "Claude did not answer initialize within \(Int(seconds))s."
		case .admissionRejected(let reason):
			return "Claude admission rejected the launch: \(reason)"
		case .admissionRejectedPostInitialize(let reason):
			return "Claude admission rejected the runtime after initialize: \(reason)"
		case .admissionCycleGuardDiverged:
			return "Claude admission cycle guard diverged; a policy-dependent value influenced command resolution."
		case .admissionAuthProvenanceDrift:
			return "Claude admission detected authentication/backend drift between resolutions; failing closed."
		case .admissionEnvelopeMissing:
			return "Claude admission envelope missing where the effective permission mode is required; failing closed."
		case .capabilityNotOffered(let reason):
			return "Claude session does not offer the requested capability: \(reason)"
		}
	}
}
