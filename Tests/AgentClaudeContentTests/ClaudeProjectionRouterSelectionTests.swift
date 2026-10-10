import XCTest
import AgentClaudeContent
import AgentClaudeProtocol
import AIClientKit
import ClaudeRuntimeKit

/// F2.6 — proves WHICH branch of the authority switch executes.
///
/// Every other test in this program compares the two lanes over real frames, and
/// F2.5 closed that gap: parity now holds over all 23 frozen golden sources and
/// both live 2.1.215 captures. That success is precisely what makes those tests
/// useless here. When both branches produce identical output, no fixture can
/// distinguish "routed through the projection" from "returned batch.results" —
/// a router that ignored `authority` entirely would pass all of them.
///
/// So these tests construct a batch whose two lanes DELIBERATELY DISAGREE. The
/// legacy lane carries one sentinel, the normalized lane projects to a different
/// one, and each authority must return its own. This is the only assertion in the
/// suite that fails if the switch is deleted, inverted, or collapsed to one arm.
final class ClaudeProjectionRouterSelectionTests: XCTestCase {

	/// A batch whose lanes cannot be confused for one another.
	///
	/// `results` says "legacy-sentinel". `normalizedEvents` holds a single
	/// `.assistantText` that projects to `content` with "normalized-sentinel".
	/// No real frame produces this pair — that is the point.
	private func divergentBatch() -> ClaudeNativeTranslationBatch {
		ClaudeNativeTranslationBatch(
			envelope: ClaudeEventEnvelope.decode(line: Data(#"{"type":"assistant"}"#.utf8)),
			results: [AIStreamResult(type: "content", text: "legacy-sentinel")],
			diagnostics: [],
			normalizedEvents: [
				.assistantText(.init(messageID: "m-sentinel", text: "normalized-sentinel", extra: [:]))
			]
		)
	}

	func testNormalizedAuthorityReturnsProjectedNormalizedOutput() {
		let output = ClaudeProjectionRouter.route(batch: divergentBatch(), authority: .normalized)

		XCTAssertEqual(
			output.results.map(\.text), ["normalized-sentinel"],
			"""
			.normalized did not route through ClaudeRuntimeEventProjection. Getting \
			"legacy-sentinel" here means the switch is absent, inverted, or both arms \
			return batch.results — none of which any parity test can detect.
			"""
		)
	}

	func testLegacyAuthorityReturnsTheSuppliedLegacyResults() {
		let output = ClaudeProjectionRouter.route(batch: divergentBatch(), authority: .legacy)

		XCTAssertEqual(
			output.results.map(\.text), ["legacy-sentinel"],
			"""
			.legacy must return batch.results untouched. It is the rollback path: if \
			it silently projects, there is no way back from a bad flip.
			"""
		)
	}

	/// The two authorities must actually differ on this input. Asserting the
	/// difference directly stops both tests from passing vacuously if the sentinels
	/// ever collapse to the same value.
	func testTheTwoAuthoritiesDisagreeOnADivergentBatch() {
		let batch = divergentBatch()
		let normalized = ClaudeProjectionRouter.route(batch: batch, authority: .normalized)
		let legacy = ClaudeProjectionRouter.route(batch: batch, authority: .legacy)

		XCTAssertNotEqual(
			normalized.results.map(\.text), legacy.results.map(\.text),
			"the sentinels stopped diverging — this test can no longer prove anything"
		)
	}

	// MARK: - Identity extraction is authority-independent

	/// Turn-aggregate identities are extracted BEFORE the switch and must be
	/// byte-identical AND identically ordered in both modes.
	///
	/// They key idempotent usage finalization. If selecting `.legacy` produced
	/// fewer identities, or the same set in a different order, finalization would
	/// behave differently per authority and the rollback path would not be a
	/// rollback.
	func testTurnAggregateIdentitiesAreIdenticalAndOrderedInBothModes() {
		let identities: [ClaudeUsageIdentity] = [
			ClaudeUsageIdentity(sessionID: "s1", messageID: "turn-1", phase: .turnAggregate),
			ClaudeUsageIdentity(sessionID: "s1", messageID: "turn-2", phase: .turnAggregate),
		]
		let batch = ClaudeNativeTranslationBatch(
			envelope: ClaudeEventEnvelope.decode(line: Data(#"{"type":"result"}"#.utf8)),
			results: [AIStreamResult(type: "content", text: "legacy-sentinel")],
			diagnostics: [],
			normalizedEvents: [
				.usage(.init(identity: identities[0], scope: .topLevel,
							 breakdown: ClaudeUsageBreakdown(inputTokens: 1, outputTokens: 1,
															 cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
							 modelContextWindow: nil, costUSD: 0.1, extra: [:])),
				// An assistantSnapshot between them: it must not be collected, and
				// must not disturb the order of those that are.
				.usage(.init(identity: ClaudeUsageIdentity(sessionID: "s1", messageID: "snap", phase: .assistantSnapshot),
							 scope: .topLevel,
							 breakdown: ClaudeUsageBreakdown(inputTokens: 2, outputTokens: 2,
															 cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
							 modelContextWindow: nil, costUSD: nil, extra: [:])),
				.usage(.init(identity: identities[1], scope: .topLevel,
							 breakdown: ClaudeUsageBreakdown(inputTokens: 3, outputTokens: 3,
															 cacheCreationInputTokens: 0, cacheReadInputTokens: 0),
							 modelContextWindow: nil, costUSD: 0.2, extra: [:])),
			]
		)

		let normalized = ClaudeProjectionRouter.route(batch: batch, authority: .normalized)
		let legacy = ClaudeProjectionRouter.route(batch: batch, authority: .legacy)

		XCTAssertEqual(normalized.turnAggregateIdentities, identities,
					   "turn aggregates must be collected in arrival order, snapshots excluded")
		XCTAssertEqual(
			normalized.turnAggregateIdentities, legacy.turnAggregateIdentities,
			"""
			identity extraction became authority-dependent. It sits before the switch \
			precisely so finalization is identical in both modes — otherwise .legacy \
			is not a true rollback.
			"""
		)
	}
}
