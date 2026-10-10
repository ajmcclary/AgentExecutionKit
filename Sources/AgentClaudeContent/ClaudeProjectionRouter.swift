import Foundation
import AIClientKit
import ClaudeRuntimeKit
import AgentClaudeProtocol

/// The shared consumer of `ClaudeNativeTranslationBatch.normalizedEvents`.
///
/// R10 scopes normalized-lane consumption to this router. Everything it returns
/// is provider-neutral or Claude-identity-only:
///
///   - `results` — the selected semantic lane, always `[AIStreamResult]`. Claude
///     runtime events never reach the transcript, persistence, or the
///     provider-neutral reducer in their own shape.
///   - `turnAggregateIdentities` — ordered turn-aggregate identities, used only
///     to key idempotent usage finalization.
///
/// Returning BOTH from one function is deliberate. "The identity must be emitted
/// before its corresponding semantic result" becomes a property of a single
/// function's output rather than a convention spread across call sites, which is
/// what makes the ordering mechanically enforceable instead of aspirational.
///
/// Lifecycle decision authority is NOT here — R12g governs that separately.
public enum ClaudeProjectionRouter {

	public struct Output: Sendable {
		/// The semantic lane the caller should emit, already selected.
		public let results: [AIStreamResult]
		/// Turn-aggregate identities in arrival order. Only `.turnAggregate`
		/// identities carrying a non-nil `messageID` qualify: nothing else names
		/// a logical turn, so nothing else may key finalization.
		public let turnAggregateIdentities: [ClaudeUsageIdentity]
	}

	/// The normalized usage events in a batch, for shadow usage accounting.
	///
	/// Exposed here so the router stays the ONE place that reads
	/// `normalizedEvents`. The shadow comparator needs usage events rather than
	/// projected results, and giving it its own direct access would make R10's
	/// "one consumer" rule an exception list instead of a rule.
	public static func usageEvents(in batch: ClaudeNativeTranslationBatch) -> [ClaudeRuntimeEvent] {
		batch.normalizedEvents.filter { if case .usage = $0 { return true } else { return false } }
	}

	/// Selects the semantic lane for `authority` and extracts turn-aggregate
	/// identities from the same batch.
	///
	/// Both projection modes run the normalized lane — selecting `.legacy` picks
	/// which SEMANTIC results are emitted, and must not downgrade finalization
	/// identity. That is why identities are extracted before, and independently
	/// of, the selection: identity is keyed off the usage lane in BOTH modes, so
	/// finalization behaves identically whichever authority is active.
	public static func route(
		batch: ClaudeNativeTranslationBatch,
		authority: ClaudeProjectionAuthority
	) -> Output {
		let identities = batch.normalizedEvents.compactMap { event -> ClaudeUsageIdentity? in
			guard case .usage(let usage) = event,
				usage.identity.phase == .turnAggregate,
				usage.identity.messageID != nil else { return nil }
			return usage.identity
		}

		// F2.6 — THE AUTHORITY SWITCH. `.normalized` now routes through the
		// projection; `.legacy` returns `batch.results` permanently.
		//
		// This was held behavior-neutral until F2.5 closed the vocabulary, because
		// routing through the projection earlier would have DROPPED every lifecycle
		// frame the normalized lane could not model. F2.5 closed it in stages, each
		// gated on evidence rather than on the corpus agreeing with itself:
		// the 19 result-producing families, then the stream sub-family the
		// 19-family count was too coarse to see, found by a live 2.1.215 capture
		// diverging at frame 19.
		//
		// Parity is now proven over all 23 frozen golden sources and both live
		// captures, full-field and per-frame. That parity is exactly why this
		// switch cannot be verified by fixtures: both branches produce identical
		// output on every real input. Which branch actually executes is proven by
		// ClaudeProjectionRouterSelectionTests using divergent sentinel lanes, and
		// pinned structurally by R10.
		let results: [AIStreamResult]
		switch authority {
		case .normalized:
			results = ClaudeNativeResultProjection.project(batch.normalizedEvents)
		case .legacy:
			results = batch.results
		}

		return Output(results: results, turnAggregateIdentities: identities)
	}
}
