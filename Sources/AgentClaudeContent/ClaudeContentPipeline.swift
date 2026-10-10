import Foundation
import AIClientKit
import AgentRuntimeKit
import ClaudeRuntimeKit
import AgentClaudeProtocol
import AgentClaudeEvents

/// Translation state, diagnostic draining and ordered semantic dispatch for one
/// native client. Actor-confined; hosts retain transport, metadata, lifecycle,
/// presentation and diagnostic storage policy. No implicit settings or logging.
public final class ClaudeContentPipeline {
	public let authority: ClaudeProjectionAuthority
	private var translator: ClaudeNativeEventTranslator
	public private(set) var diagnostics = ClaudeRuntimeDiagnosticAccumulator()

	public init(authority: ClaudeProjectionAuthority, enableDebugLogging: Bool = false, policy: ClaudeTranslatorPolicy) {
		self.authority = authority
		self.translator = ClaudeNativeEventTranslator(enableDebugLogging: enableDebugLogging, policy: policy)
	}

	/// Returns semantic work only after the redacted diagnostic lane is drained.
	/// Translation state survives process reconnects, as in the native client.
	public func translate(_ data: Data) -> ClaudeContentFrame {
		let batch = translator.translate(data)
		for diagnostic in batch.diagnostics { diagnostics.record(diagnostic) }
		return ClaudeContentFrame.project(batch: batch, authority: authority, translatorSessionID: translator.cliSessionID)
	}
}

/// An immutable ordered projection, without raw envelopes or runtime events.
/// Hosts interpret every step in order; session observations precede the related
/// result, and usage identity immediately precedes its top-level message_stop.
public struct ClaudeContentFrame: Sendable {
	public enum Step: Sendable {
		case sessionID(String)
		case observeResult(AIStreamResult, suppressed: Bool)
		case emit(ClaudeNativeEvent)
	}
	/// Selected, unfiltered results for host diagnostics; emit only `steps`.
	public let results: [AIStreamResult]
	public let steps: [Step]

	public static func project(batch: ClaudeNativeTranslationBatch, authority: ClaudeProjectionAuthority, translatorSessionID: String? = nil) -> Self {
		let projection = ClaudeProjectionRouter.route(batch: batch, authority: authority)
		let identity = projection.turnAggregateIdentities.first
		var didEmitIdentity = false
		var steps: [Step] = []
		if let translatorSessionID, !translatorSessionID.isEmpty { steps.append(.sessionID(translatorSessionID)) }
		for result in projection.results {
			if let id = result.providerSessionID, !id.isEmpty { steps.append(.sessionID(id)) }
			// These are run-state updates, not transcript rows. Preserve forwarding
			// independently of the transcript-noise suppression policy.
			let suppressed = result.type != "session_state_changed" && result.type != "task_progress"
				&& shouldSuppressUserFacingStreamResult(result)
			steps.append(.observeResult(result, suppressed: suppressed))
			guard !suppressed else { continue }
			if batch.envelope.type == "result", result.type == "message_stop", !didEmitIdentity, let identity {
				didEmitIdentity = true
				steps.append(.emit(.turnAggregateIdentity(identity)))
			}
			steps.append(.emit(.stream(result)))
		}
		return Self(results: projection.results, steps: steps)
	}

	public static func shouldSuppressUserFacingStreamResult(_ result: AIStreamResult) -> Bool {
		// Reasoning remains runtime preview data; transcript suppression belongs
		// to presentation. Child task infrastructure must not end a text segment.
		if result.type == "system", let text = result.text,
			(text.hasPrefix("Task started") || text.hasPrefix("Task update")) { return true }
		guard result.type == "error", let text = result.text,
			!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		return ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(text)
	}
}
