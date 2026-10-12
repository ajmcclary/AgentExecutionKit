import XCTest
import Foundation
import AgentUsage
import AgentRuntimeKit

final class AgentUsageRestorationTests: XCTestCase {
    private func row(prompt: Int = 0, completion: Int = 0, context: Int? = nil, estimate: Int = 0) -> AgentTokenUsagePersist {
        .init(promptTokens: prompt, completionTokens: completion, contextUsedTokens: context, estimatedUserInputTokens: estimate)
    }
    func testClaudeRestorationTrustsOnlyLatestInWindowContextNotBilledTotals() {
        let rows = [row(context: 50), row(prompt: 900, completion: 100), row(context: 201)]
        XCTAssertEqual(AgentUsageRestoration.claude(rows, modelContextWindow: 200), .init(modelContextWindow: 200, lastTotalTokens: 50, totalTotalTokens: 50))
        XCTAssertNil(AgentUsageRestoration.claude([row(prompt: 900)], modelContextWindow: nil))
    }
    func testClaudeDefaultAdmissionWindowDoesNotFabricatePersistedModelWindow() {
        let result = AgentUsageRestoration.claude([row(context: 200_000),row(context: 200_001)], modelContextWindow: nil)
        XCTAssertNil(result?.modelContextWindow)
        XCTAssertEqual(result?.lastTotalTokens, 200_000)
    }
    func testOpenCodeUsesLatestAbsoluteReadingAndOnlyThenProviderTotal() {
        let result = AgentUsageRestoration.openCode([row(context: 100),row(context: 200),row(prompt: 7, completion: 3)], modelContextWindow: 500)
        XCTAssertEqual(result?.lastTotalTokens, 10); XCTAssertEqual(result?.totalTotalTokens, 10)
        let contextFirst = AgentUsageRestoration.openCode([row(prompt: 700, completion: 300, context: 900)], modelContextWindow: 100)
        XCTAssertEqual(contextFirst?.lastTotalTokens, 900)
    }
    func testGeminiCumulativeAndLastReadingUseProviderTotalThenEstimatedInput() {
        let result = AgentUsageRestoration.gemini([row(prompt: 7,completion: 3,context: 500),row(estimate: 4)], modelContextWindow: 100)
        XCTAssertEqual(result?.lastTotalTokens, 4); XCTAssertEqual(result?.totalTotalTokens, 14)
    }
    func testGeminiCumulativeTotalSaturatesAtExistingPersistedBound() {
        let value = row(prompt: AgentTokenUsagePersist.maxPersistedTokenCount, completion: AgentTokenUsagePersist.maxPersistedTokenCount)
        let result = AgentUsageRestoration.gemini([value,value], modelContextWindow: nil)
        XCTAssertEqual(result?.lastTotalTokens, 2_000_000_000_000)
        XCTAssertEqual(result?.totalTotalTokens, 1_000_000_000_000)
    }
    func testEmptyAndUnknownEvidenceNeverInventsZeroUsage() {
        for provider in AgentUsageRestoration.Provider.allCases {
            XCTAssertNil(AgentUsageRestoration.restore(for: provider, tokens: [], existing: nil))
        }
        for projection in [AgentUsageRestoration.claude,AgentUsageRestoration.openCode,AgentUsageRestoration.gemini] {
            XCTAssertNil(projection([row()], nil))
            XCTAssertEqual(projection([row()], 100), .init(modelContextWindow: 100, lastTotalTokens: nil, totalTotalTokens: nil))
        }
    }
    func testReopenPreservesExactClaudeSnapshotAndNativeOrOpaqueUsage() {
        let existing = AgentContextUsage(modelContextWindow: 200_000, lastTotalTokens: 400, totalTotalTokens: 400)
        let rows = [row(context: 900)]
        XCTAssertEqual(AgentUsageRestoration.restore(for: .claude, tokens: rows, existing: existing), existing)
        XCTAssertEqual(AgentUsageRestoration.restore(for: .passthrough, tokens: rows, existing: existing), existing)
    }
    func testReopenRebuildsClaudeUnknownAndReplacesGeminiAndOpenCode() {
        let unknown = AgentContextUsage(modelContextWindow: 1000)
        let rows = [row(prompt: 3, completion: 2, context: 80), row(prompt: 4, completion: 1, context: 90)]
        XCTAssertEqual(AgentUsageRestoration.restore(for: .claude, tokens: rows, existing: unknown)?.lastTotalTokens, 90)
        XCTAssertEqual(AgentUsageRestoration.restore(for: .openCode, tokens: rows, existing: unknown)?.totalTotalTokens, 90)
        XCTAssertEqual(AgentUsageRestoration.restore(for: .gemini, tokens: rows, existing: unknown)?.totalTotalTokens, 10)
    }
    func testSnapshotRequiresUsageOrWindowOrCompactionEvidence() {
        XCTAssertNil(ContextUsageSnapshot.fromAgentContextUsage(nil, source: .persistedTurns, confidence: .inferred))
        let date = Date(timeIntervalSince1970: 123)
        let compacted = ContextUsageSnapshot.fromAgentContextUsage(nil, source: .compactionSignal, confidence: .bestEffort, compactedAt: date)
        XCTAssertNil(compacted?.used); XCTAssertNil(compacted?.window); XCTAssertEqual(compacted?.compactedAt, date)
        let knownWindow = ContextUsageSnapshot.fromAgentContextUsage(.init(modelContextWindow: 100), source: .persistedTurns, confidence: .inferred)
        XCTAssertEqual(knownWindow?.window, 100); XCTAssertNil(knownWindow?.used)
    }
    func testSnapshotCodableFieldAndEnumValuesRemainStable() throws {
        let value = ContextUsageSnapshot(used: 7, window: 100, confidence: .exact, source: .codexNativeUsage, compactedAt: Date(timeIntervalSinceReferenceDate: 0))
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["used","window","confidence","source","compactedAt"]))
        XCTAssertEqual(object["source"] as? String, "codexNativeUsage")
        XCTAssertEqual(object["confidence"] as? String, "exact")
        XCTAssertEqual(try JSONDecoder().decode(ContextUsageSnapshot.self, from: data), value)
        let sources: [ContextUsageSnapshotSource] = [.claudeUsageEvent,.geminiUsageEvent,.openCodeUsageEvent,.codexNativeUsage,.turnFinalization,.persistedTurns,.compactionSignal]
        XCTAssertEqual(sources.map(\.rawValue), ["claudeUsageEvent","geminiUsageEvent","openCodeUsageEvent","codexNativeUsage","turnFinalization","persistedTurns","compactionSignal"])
        XCTAssertEqual([ContextUsageSnapshotConfidence.exact,.bestEffort,.inferred].map(\.rawValue), ["exact","bestEffort","inferred"])
    }
    func testFutureSnapshotSourceStillRejectsRatherThanInferringConfidence() {
        XCTAssertThrowsError(try JSONDecoder().decode(ContextUsageSnapshot.self, from: Data("{\"confidence\":\"exact\",\"source\":\"future\"}".utf8)))
    }
}
