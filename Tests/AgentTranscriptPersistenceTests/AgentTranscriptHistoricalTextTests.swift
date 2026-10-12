import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptPersistence

final class AgentTranscriptHistoricalTextTests:XCTestCase {
    private func policy() -> AgentTranscriptHistoricalTextPolicy {
        .init { text,limit,marker in
            let cap=limit*4
            guard text.utf8.count>cap else{return text}
            return String(text.prefix(cap/2))+marker+String(text.suffix(cap/2))
        }
    }
    private func largeTurn(_ index:Int) -> AgentTranscriptTurn {
        var turn=fixtureTurn(index)
        turn.responseSpans[0].activities=[fixtureActivity(index*10+1,text:String(repeating:"x",count:60_000))]
        return turn
    }
    func testDefaultMostRecentThreeTurnsAreExemptAndOlderTextIsTruncated() {
        let original=AgentTranscript(turns:(0..<5).map{largeTurn($0)})
        let result=policy().truncatedTranscript(original)
        XCTAssertTrue(result.turns[0].allActivities[0].text.contains("[content truncated]"))
        XCTAssertTrue(result.turns[1].allActivities[0].text.contains("[content truncated]"))
        XCTAssertEqual(Array(result.turns.suffix(3)),Array(original.turns.suffix(3)))
        XCTAssertEqual(original.turns[0].allActivities[0].text.count,60_000)
    }
    func testUserSystemAndToolArgumentsOrResultJSONRemainUnchanged() {
        var turn=largeTurn(0)
        var user=fixtureActivity(1,kind:.user,text:String(repeating:"u",count:60_000))
        user.attachments=[.init(source:.url("https://example.com/image.png"))]
        let system=fixtureActivity(2,kind:.system,text:String(repeating:"s",count:60_000))
        var tool=fixtureActivity(3,kind:.toolResult,status:.success,text:String(repeating:"r",count:60_000))
        tool.toolExecution?.argsJSON=String(repeating:"a",count:60_000);tool.toolExecution?.resultJSON=String(repeating:"j",count:60_000)
        turn.responseSpans[0].activities=[user,system,tool]
        let result=policy().truncatedTranscript(.init(turns:[turn]),exemptTurnCount:0).turns[0].allActivities
        XCTAssertEqual(result[0],user);XCTAssertEqual(result[1],system)
        XCTAssertEqual(result[2].toolExecution,tool.toolExecution)
        XCTAssertLessThan(result[2].text.count,tool.text.count)
    }
    func testReasoningAndCompactedSummaryFieldsUseSameInjectedTruncator() {
        var turn=largeTurn(0)
        turn.responseSpans[0].activities[0].reasoning=String(repeating:"r",count:60_000)
        var summary=fixtureSummary(turn)
        summary.requestText=String(repeating:"u",count:60_000)
        summary.middleSummaryText=String(repeating:"m",count:60_000)
        summary.conclusionText=String(repeating:"c",count:60_000)
        summary.compactConclusionText=String(repeating:"s",count:60_000)
        turn.summary=summary
        let result=policy().truncatedTranscript(.init(turns:[turn]),exemptTurnCount:0).turns[0]
        XCTAssertEqual(result.summary?.requestText,summary.requestText)
        XCTAssertTrue(result.summary?.middleSummaryText?.contains("[content truncated]")==true)
        XCTAssertTrue(result.summary?.conclusionText?.contains("[content truncated]")==true)
        XCTAssertTrue(result.summary?.compactConclusionText?.contains("[content truncated]")==true)
        XCTAssertTrue(result.allActivities[0].reasoning?.contains("[content truncated]")==true)
    }
    func testExportRecencyIsRelativeToSelectedSlice() {
        let all=(0..<8).map{largeTurn($0)}
        let slice=Array(all[1...5])
        let result=policy().truncatedExportSlice(slice)
        XCTAssertNotEqual(result[0].allActivities[0].text,slice[0].allActivities[0].text)
        XCTAssertEqual(Array(result.suffix(3)),Array(slice.suffix(3)))
        XCTAssertEqual(result.map(\.id),slice.map(\.id))
    }
    func testSimulationCountsOnlyFullDetailAndCapsEligibleFieldsUsingUTF8Bytes() {
        var turn=fixtureTurn(0)
        var activity=fixtureActivity(1,text:String(repeating:"x",count:60_000));activity.reasoning=String(repeating:"r",count:60_000)
        turn.responseSpans[0].activities=[activity]
        let original=AgentTranscript(turns:[turn,fixtureTurn(1,tier:.summary)])
        XCTAssertEqual(policy().simulatedRetainedFullDetailBytes(for:original,exemptTurnCount:0),80_000)
        XCTAssertEqual(policy().simulatedRetainedFullDetailBytes(for:original),120_000)
    }
    func testNegativeExemptionIsBoundedToZeroAndLargeExemptionLeavesSourceUnchanged() {
        let original=AgentTranscript(turns:[largeTurn(0)])
        XCTAssertEqual(policy().truncatedTranscript(original,exemptTurnCount:-1),policy().truncatedTranscript(original,exemptTurnCount:0))
        XCTAssertEqual(policy().truncatedExportSlice(original.turns,exemptTurnCount:-1),policy().truncatedExportSlice(original.turns,exemptTurnCount:0))
        XCTAssertEqual(policy().simulatedRetainedFullDetailBytes(for:original,exemptTurnCount:-1),80_000-40_000)
        XCTAssertEqual(policy().truncatedTranscript(original,exemptTurnCount:99),original)
    }
    func testEmptyAndSmallTranscriptsRemainByteEquivalentAfterRoundTrip() throws {
        let original=AgentTranscript(turns:[fixtureTurn(0)])
        XCTAssertEqual(policy().truncatedTranscript(original),original)
        XCTAssertEqual(policy().truncatedTranscript(.empty),.empty)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(policy().truncatedTranscript(original)),try encoder.encode(original))
    }
}
