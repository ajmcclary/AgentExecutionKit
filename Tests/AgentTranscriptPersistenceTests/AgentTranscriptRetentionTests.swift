import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptPersistence

final class AgentTranscriptRetentionTests: XCTestCase {
    func testPressureDownshiftsOldestCompletedTurnsAndKeepsNewestFull() {
        let original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0) }, nextSequenceIndex: 322)
        let service = fixtureRetentionService(), result = service.compact(original)
        XCTAssertLessThanOrEqual(service.estimatedWorkingUnitCount(for: result), 55)
        XCTAssertEqual(result.turns.last?.retentionTier, .full)
        XCTAssertEqual(result.turns.map(\.id), original.turns.map(\.id))
        XCTAssertEqual(result.nextSequenceIndex, original.nextSequenceIndex)
        XCTAssertEqual(original.turns.filter { $0.retentionTier == .full }.count,32)
    }
    func testExplicitProtectedTurnAndNewestAreNeverDownshifted() {
        let original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0) })
        let result = fixtureRetentionService().compact(original, protectedTurnID: original.turns[0].id)
        XCTAssertEqual(result.turns[0].retentionTier, .full)
        XCTAssertEqual(result.turns.last?.retentionTier, .full)
    }
    func testRecentEightToolExecutionSuffixRetainsWholeTurns() {
        let original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0, tools: true) })
        let result = fixtureRetentionService().compact(original)
        XCTAssertTrue(result.turns.suffix(8).allSatisfy { $0.retentionTier == .full })
        XCTAssertTrue(result.turns.dropLast(8).contains { $0.retentionTier != .full })
    }
    func testSuppressedToolsDoNotConsumeProtectedTailBudget() {
        let original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0, tools: true) })
        let result = fixtureRetentionService(suppress: { _ in true }).compact(original)
        XCTAssertEqual(result.turns[24].retentionTier, .summary)
        XCTAssertEqual(result.turns.last?.retentionTier, .full)
    }
    func testSeparateCallAndResultCountOncePerExecution() {
        var original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0) })
        for index in 20..<32 {
            original.turns[index].responseSpans[0].activities = [
                fixtureActivity(index*10+1, kind: .toolCall, status: .pending, executionID: "same-\(index)"),
                fixtureActivity(index*10+2, kind: .toolResult, status: .success, executionID: "same-\(index)")]
        }
        let result = fixtureRetentionService().compact(original)
        XCTAssertTrue(result.turns.suffix(8).allSatisfy { $0.retentionTier == .full })
        XCTAssertNotEqual(result.turns[23].retentionTier, .full)
    }
    func testUnorderedActivitiesUseSequenceThenTimestampAndDiagnosticsAreEquivalent() {
        var original = AgentTranscript(turns: (0..<32).map { fixtureTurn($0, tools: true) })
        original.turns[31].responseSpans[0].activities.reverse()
        var scan: AgentTranscriptProtectedTailScanMetrics?
        let debug = fixtureRetentionService(diagnostics: true, observeTail: { scan=$0 }).compact(original)
        XCTAssertEqual(debug,fixtureRetentionService().compact(original))
        XCTAssertEqual(scan?.sortedSpanCount,1)
        XCTAssertEqual(scan?.countedToolExecutionCount,8)
        XCTAssertEqual(scan?.durationMS,0)
    }
    func testSoftGuardSkipsTailScanButStillTrimsExistingNonFullTurns() {
        var turn = fixtureTurn(0,tier: .condensed)
        turn.summary = fixtureSummary(turn)
        var compaction: AgentTranscriptCompactionMetrics?; var scans=0
        let service = fixtureRetentionService(diagnostics:true,observeCompaction:{compaction=$0},observeTail:{_ in scans+=1})
        let result = service.compact(.init(turns:[turn]))
        XCTAssertEqual(scans,0); XCTAssertEqual(compaction?.softGuardSkippedScan,true)
        XCTAssertEqual(result.turns[0].responseSpans[0].activities.map(\.id),[turn.conclusionActivityID!])
        XCTAssertNil(result.turns[0].summary?.requestText)
        XCTAssertEqual(result.turns[0].summary?.compactConclusionText,"compact:conclusion")
    }
    func testHardPressureArchivesOldestEligibleSummariesWithoutRemovingTurns() {
        let turns=(0..<100).map { fixtureTurn($0,tier:.summary) }+[fixtureTurn(100)]
        var metrics:AgentTranscriptCompactionMetrics?
        let result=fixtureRetentionService(diagnostics:true,observeCompaction:{metrics=$0}).compact(.init(turns:turns))
        XCTAssertEqual(result.turns.count,101)
        XCTAssertEqual(result.turns.filter{$0.retentionTier == .archived}.count,35)
        XCTAssertEqual(metrics?.archiveIterationCount,1);XCTAssertEqual(metrics?.archivedTurnCount,35)
        XCTAssertEqual(metrics?.finalWorkingUnitCount,70)
    }
    func testSummaryToolSignalsProtectOtherwiseEmptyCompactedTurns() {
        var turns=(0..<100).map { fixtureTurn($0,tier:.summary) }
        for index in 91..<100 { turns[index].responseSpans=[];turns[index].summary=fixtureSummary(turns[index],toolCount:1) }
        let result=fixtureRetentionService().compact(.init(turns:turns+[fixtureTurn(100)]))
        XCTAssertTrue(result.turns[92..<100].allSatisfy{$0.retentionTier == .summary})
    }
    func testActiveContinuationPreservesLatestCompletedFullAnchor() {
        let turns=(0..<32).map { fixtureTurn($0) }+[fixtureTurn(32,completed:false)]
        let result=fixtureRetentionService().compact(.init(turns:turns))
        XCTAssertEqual(result.turns[31].retentionTier,.full)
        XCTAssertEqual(result.turns[32].retentionTier,.full)
    }
    func testDurableFrontierPreservesOriginalFrozenPrefixEvenUnderPressure() {
        var prefix=fixtureTurn(0,tier:.summary);prefix.summary=fixtureSummary(prefix)
        var original=AgentTranscript(turns:[prefix]+(1..<40).map{fixtureTurn($0)})
        original=AgentTranscriptDurableFrontierSupport.normalizedTranscript(original)
        let result=fixtureRetentionService().compact(original,mode:.preserveDurableFrontier)
        XCTAssertEqual(result.turns[0],prefix)
        XCTAssertEqual(result.compactionFrontier?.lastFrozenTurnID,result.turns[result.compactionFrontier!.frozenPrefixTurnCount-1].id)
    }
    func testInvalidFrontierFallsBackToRecompute() {
        var original=AgentTranscript(turns:(0..<32).map{fixtureTurn($0)})
        original.compactionFrontier = .init(version:99,frozenPrefixTurnCount:1,lastFrozenTurnID:UUID())
        let service=fixtureRetentionService()
        XCTAssertEqual(service.compact(original,mode:.preserveDurableFrontier),service.compact(original,mode:.recomputeAll))
    }
    func testArchivedAndSummaryTiersKeepConclusionIDOnlyAndDropCaches() {
        for tier in [AgentTranscriptRetentionTier.condensed,.summary,.archived] {
            var turn=fixtureTurn(0,tier:tier);turn.summary=fixtureSummary(turn)
            turn.responseSpans[0].fullRenderGroupedHistoryCache = .init(detailedToolTailLimit:8,collapseDigest:"digest",summary:fixtureGroupedSummary())
            let result=fixtureRetentionService().compact(.init(turns:[turn])).turns[0]
            XCTAssertEqual(result.responseSpans[0].activities.map(\.id),[turn.conclusionActivityID!])
            XCTAssertNil(result.responseSpans[0].fullRenderGroupedHistoryCache)
            XCTAssertEqual(result.responseSpans[0].collapsedSummary == nil,tier == .archived)
            XCTAssertEqual(result.summary?.conclusionText == nil,tier != .condensed)
        }
    }
    func testRetainedByteMeasurementDoesNotDoubleCountResultText() {
        var turn=fixtureTurn(0)
        var activity=fixtureActivity(1,kind:.toolResult,status:.success,text:"é🙂")
        activity.reasoning="why";activity.toolExecution?.argsJSON="args";activity.toolExecution?.summaryText="sum"
        turn.responseSpans[0].activities=[activity]
        let service=fixtureRetentionService()
        XCTAssertEqual(service.retainedFullDetailBytes(for:.init(turns:[turn])),6+3+4+3)
        turn.retentionTier = .summary
        XCTAssertEqual(service.retainedFullDetailBytes(for:.init(turns:[turn])),0)
    }
    func testFullTierClearsSummaryCachesAndKeepsAllActivities() {
        var turn=fixtureTurn(0);turn.summary=fixtureSummary(turn);turn.responseSpans[0].collapsedSummary=fixtureGroupedSummary()
        let result=fixtureRetentionService().compact(.init(turns:[turn])).turns[0]
        XCTAssertNil(result.summary);XCTAssertNil(result.responseSpans[0].collapsedSummary)
        XCTAssertEqual(result.responseSpans[0].activities,turn.responseSpans[0].activities)
    }
}
