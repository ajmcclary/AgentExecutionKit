import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptPersistence

final class AgentTranscriptColdRestoreTests:XCTestCase {
    func testRunStateNormalizationPreservesTerminalUnknownAndRawFutureValues() {
        for state in [AgentSessionRunState.running,.waitingForUser,.waitingForQuestion,.waitingForApproval] { XCTAssertEqual(AgentTranscriptColdRestore.normalizedRunState(state),.idle) }
        for state in [AgentSessionRunState.idle,.completed,.cancelled,.failed] { XCTAssertEqual(AgentTranscriptColdRestore.normalizedRunState(state),state) }
        XCTAssertEqual(AgentTranscriptColdRestore.normalizedRunState(nil),.idle)
        XCTAssertNil(AgentTranscriptColdRestore.normalizedLastRunStateRaw(nil))
        XCTAssertEqual(AgentTranscriptColdRestore.normalizedLastRunStateRaw("future-value"),"future-value")
        XCTAssertEqual(AgentTranscriptColdRestore.normalizedLastRunStateRaw(" running ")," running ")
    }
    func testOrphanActiveRunClosesSpansCancelsToolsAndStopsStreaming() throws {
        var turn=fixtureTurn(0,completed:false)
        turn.responseSpans[0].activities=[fixtureActivity(1,kind:.toolCall,status:.pending,executionID:"active"),fixtureActivity(2,kind:.toolResult,status:.running,executionID:"active",text:"{\"process_id\":\"123\",\"custom\":5}")]
        turn.responseSpans[0].activities[1].isStreaming=true
        turn.summary=fixtureSummary(turn)
        let result=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0]
        XCTAssertEqual(result.terminalState,.cancelled);XCTAssertNotNil(result.completedAt)
        XCTAssertEqual(result.responseSpans[0].lifecycle,.cancelled);XCTAssertNotNil(result.responseSpans[0].completedAt)
        XCTAssertTrue(result.responseSpans[0].activities.allSatisfy{!$0.isStreaming && $0.toolExecution?.status == .cancelled})
        XCTAssertEqual(result.summary?.hadError,true)
        let raw=result.responseSpans[0].activities[1].text
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
        XCTAssertEqual(object["status"] as? String,"cancelled");XCTAssertEqual(object["reason"] as? String,"restored_without_live_run")
        XCTAssertEqual(object["process_id"] as? String,"123");XCTAssertEqual(object["custom"] as? Int,5)
        XCTAssertEqual(result.responseSpans[0].activities[1].toolExecution?.resultJSON,raw)
    }
    func testTerminalFamilyKeepsOriginalPendingCallStatusRatherThanCancellingCompletedWork() {
        var turn=fixtureTurn(0)
        turn.responseSpans[0].activities=[fixtureActivity(1,kind:.toolCall,status:.pending,executionID:"done"),fixtureActivity(2,kind:.toolResult,status:.success,executionID:"done")]
        let result=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0]
        XCTAssertEqual(result.responseSpans[0].activities.compactMap{$0.toolExecution?.status},[.pending,.success])
        XCTAssertEqual(result.terminalState,.completed)
    }
    func testUnknownHigherRankEvidenceDoesNotBecomeCancellation() {
        var turn=fixtureTurn(0)
        turn.responseSpans[0].activities=[fixtureActivity(1,kind:.toolCall,status:.unknown,executionID:"unknown"),fixtureActivity(2,kind:.toolResult,status:.running,executionID:"unknown")]
        let result=AgentTranscriptColdRestore.sanitize(.init(turns:[turn]))
        XCTAssertEqual(result.turns[0].responseSpans[0].activities.compactMap{$0.toolExecution?.status},[.unknown,.running])
    }
    func testUnmarkedOpenSpanCancelsTurnAndDerivesCompletionFromStoredDates() {
        var turn=fixtureTurn(0,completed:false);turn.terminalState=nil;turn.lastActivityAt=Date(timeIntervalSince1970:90)
        let result=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0]
        XCTAssertEqual(result.terminalState,.cancelled);XCTAssertEqual(result.completedAt,Date(timeIntervalSince1970:90))
    }
    func testFailedAndCancelledTurnsCloseOpenSpansWithMatchingTerminalLifecycle() {
        for state in [AgentSessionRunState.failed,.cancelled,.completed] {
            var turn=fixtureTurn(0,completed:false);turn.terminalState=state
            let result=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0]
            XCTAssertEqual(result.responseSpans[0].lifecycle,state == .failed ? .failed : state == .cancelled ? .cancelled : .completed)
        }
    }
    func testColdRestoreSanitizesFrozenRunningSummariesAndClearsTransientCache() {
        var turn=fixtureTurn(0,tier:.summary)
        turn.responseSpans[0].collapsedSummary=fixtureGroupedSummary(running:true)
        turn.responseSpans[0].fullRenderGroupedHistoryCache = .init(detailedToolTailLimit:8,collapseDigest:"digest",summary:fixtureGroupedSummary(running:true))
        let span=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0].responseSpans[0]
        XCTAssertNil(span.fullRenderGroupedHistoryCache)
        XCTAssertEqual(span.collapsedSummary?.toolSummary?.containsRunningWork,false)
        XCTAssertEqual(span.collapsedSummary?.toolSummary?.containsFailure,true)
        XCTAssertEqual(span.collapsedSummary?.collapsedDisplay?.status,.failure)
        XCTAssertEqual(span.collapsedSummary?.toolSummary?.toolNameCounts,["read":1])
    }
    func testMalformedOrNonObjectToolResultGetsCancellationEnvelope() throws {
        for raw in ["broken","[]","", "123"] {
            var turn=fixtureTurn(0,completed:false);turn.responseSpans[0].activities=[fixtureActivity(1,kind:.toolResult,status:.running,text:raw)]
            let activity=AgentTranscriptColdRestore.sanitize(.init(turns:[turn])).turns[0].responseSpans[0].activities[0]
            let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(activity.text.utf8)) as? [String:Any])
            XCTAssertEqual(object["status"] as? String,"cancelled");XCTAssertEqual(object["tool"] as? String,"read")
        }
    }
    func testColdRestoreIsIdempotentAndPreservesRawIdentityAndFrontier() {
        var original=AgentTranscript(turns:[fixtureTurn(0,tier:.summary),fixtureTurn(1,completed:false)],nextSequenceIndex:99)
        original=AgentTranscriptDurableFrontierSupport.normalizedTranscript(original)
        let once=AgentTranscriptColdRestore.sanitize(original)
        XCTAssertEqual(AgentTranscriptColdRestore.sanitize(once),once)
        XCTAssertEqual(once.turns.map(\.id),original.turns.map(\.id))
        XCTAssertEqual(once.compactionFrontier,original.compactionFrontier);XCTAssertEqual(once.nextSequenceIndex,99)
    }
}
