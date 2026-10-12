import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptAssembly

final class AgentTranscriptReadbackTests:XCTestCase {
    private func reader(suppress:@escaping(AgentChatItem)->Bool={_ in false},name:@escaping(String?)->String?={$0})->AgentTranscriptReadback {
        .init(renderRows:{turn,_ in turn.allActivities.map{$0.toItem()}},suppressRow:suppress,visibleToolName:name)
    }
    func testWorkingSourceOnlyIncludesFullTurnsAndSortsSequenceTimestamp() {
        var transcript=assembly().importLegacyItems([row(0,kind:.user),row(1),row(2,kind:.user),row(3),row(4,kind:.user),row(5)])
        transcript.turns[0].retentionTier = .archived;transcript.turns[1].retentionTier = .summary
        XCTAssertEqual(AgentTranscriptReadback.workingSourceItems(from:transcript).map(\.sequenceIndex),[4,5])
    }
    func testResumeHistoryPreservesExistingMarkupAndSuppressionSemantics() {
        let items=[row(0,kind:.user,text:"user <raw>"),row(1,text:"  answer  "),row(2,kind:.system,text:"system"),row(3,kind:.error,text:"error"),row(4,kind:.thinking,text:"thought")]
        let transcript=assembly().importLegacyItems(items)
        XCTAssertEqual(reader().conversationHistory(from:transcript),"<user>user <raw></user>\n<assistant>answer</assistant>\n<system>system</system>\n<error>error</error>")
        XCTAssertEqual(reader(suppress:{$0.kind == .error}).conversationHistory(from:transcript),"<user>user <raw></user>\n<assistant>answer</assistant>\n<system>system</system>")
    }
    func testResumeHistoryUsesHostUserRenderingToolNamesAndRawArguments() {
        var call=row(1,kind:.toolCall,name:"raw");call.toolArgsJSON="{\"path\":\"file\"}"
        let transcript=assembly().importLegacyItems([row(0,kind:.user),call,row(2,kind:.toolResult,name:"raw")])
        let output=reader(name:{_ in "canonical"}).conversationHistory(from:transcript,renderUserMessage:{_ in "rendered"})
        XCTAssertEqual(output,"<user>rendered</user>\n<tool_call name=\"canonical\">{\"path\":\"file\"}</tool_call>\n<tool_result name=\"canonical\"/>")
    }
    func testEmptyArgsUseSelfClosingCallAndUnnamedToolsAreOmitted() {
        let transcript=assembly().importLegacyItems([row(0,kind:.user),row(1,kind:.toolCall,name:"read"),row(2,kind:.toolResult)])
        XCTAssertEqual(reader().conversationHistory(from:transcript),"<user>answer</user>\n<tool_call name=\"read\"/>")
    }
    func testDisplaylessAssistantIsOmittedAndArchivedRenderingFlagIsPassed() {
        var flags:[Bool]=[]
        var transcript=assembly().importLegacyItems([row(0,kind:.user),row(1,text:"   ")]);transcript.turns[0].retentionTier = .archived
        let reader=AgentTranscriptReadback(renderRows:{turn,archived in flags.append(archived);return turn.allActivities.map{$0.toItem()}},suppressRow:{_ in false},visibleToolName:{$0})
        XCTAssertEqual(reader.conversationHistory(from:transcript),"<user>answer</user>");XCTAssertEqual(flags,[true])
    }
    func testEmptyHistoryIsEmptyWithoutCallingHostRenderer() {
        var calls=0
        let reader=AgentTranscriptReadback(renderRows:{_,_ in calls+=1;return []},suppressRow:{_ in false},visibleToolName:{$0})
        XCTAssertEqual(reader.conversationHistory(from:.empty),"");XCTAssertEqual(calls,0)
    }
    func testRecencyClassifiesQuestionResponseSkipTimeoutAndPreservesKeyPresence() {
        let policy=AgentTranscriptRecencyPolicy(isQuestionTool:{$0 == "question"})
        for result in ["{\"response\":\"yes\"}","{\"response\":null}","{\"skipped\":true}","{\"timed_out\":true}"] {
            XCTAssertTrue(policy.isUserInteractionItem(row(1,kind:.toolResult,name:"question",result:result)))
        }
        for result in [nil,"broken","[]","{}","{\"skipped\":false}"] {
            XCTAssertFalse(policy.isUserInteractionItem(row(1,kind:.toolResult,name:"question",result:result)))
        }
        XCTAssertFalse(policy.isUserInteractionItem(row(1,kind:.toolCall,name:"question",result:"{\"response\":1}")))
    }
    func testRecencyUsesLastPhysicalInteractionForItemsAndLatestStoredTurnForTranscript() {
        let policy=AgentTranscriptRecencyPolicy(isQuestionTool:{_ in false})
        let old=row(0,kind:.user,date:100),new=row(1,kind:.user,date:10)
        XCTAssertEqual(policy.lastUserInteractionDate(in:[old,new]),new.timestamp)
        let transcript=assembly().importLegacyItems([old,row(2,text:"a"),new])
        // Assembly sorts by sequence; transcript recency uses turn order, not a global date maximum.
        XCTAssertEqual(policy.lastUserInteractionDate(in:transcript),new.timestamp)
    }
    func testRecencyUsesSummaryAndRequestEvidenceEvenWithoutStoredActivities() {
        let policy=AgentTranscriptRecencyPolicy(isQuestionTool:{_ in false})
        let request=AgentTranscriptRequestAnchor(from:row(0,kind:.user,date:100))
        var turn=AgentTranscriptTurn(request:request,startedAt:request.timestamp)
        turn.summary = .init(requestText:nil,conclusionText:nil,compactConclusionText:nil,middleSummaryText:nil,toolCount:0,notableToolNames:[],keyPaths:[],compactedActivityCount:0,hadWarning:false,hadError:false,lastUserInteractionAt:Date(timeIntervalSince1970:200))
        XCTAssertEqual(policy.lastUserInteractionDate(in:.init(turns:[turn])),Date(timeIntervalSince1970:200))
    }
    func testRowPolicyAppliesHostHiddenAndQuestionRulesOnlyToToolRows() {
        let policy=AgentTranscriptRowImportPolicy(isHiddenTool:{$0 == "hidden"},isQuestionTool:{$0 == "question"})
        let rows=[row(0,kind:.user,name:"hidden"),row(1,kind:.toolCall,name:"hidden"),row(2,kind:.toolResult,name:"hidden"),row(3,kind:.toolCall,name:"question"),row(4,kind:.toolResult,name:"question")]
        XCTAssertEqual(policy.filtered(rows).map(\.sequenceIndex),[0,3,4])
        XCTAssertEqual(policy.filtered(rows,policy:.liveSession(hidePendingQuestionToolCall:true)).map(\.sequenceIndex),[0,4])
        XCTAssertEqual(policy.filtered(rows,policy:.init(hideAlwaysHiddenTools:false)),rows)
        XCTAssertTrue(policy.containsExcluded(rows));XCTAssertFalse(policy.containsExcluded([rows[0]]))
    }
    func testRowPolicyChecksFullTranscriptIncludingFrozenTurns() {
        let policy=AgentTranscriptRowImportPolicy(isHiddenTool:{$0 == "hidden"},isQuestionTool:{_ in false})
        var transcript=assembly().importLegacyItems([row(0,kind:.user),row(1,kind:.toolResult,name:"hidden")])
        transcript.turns[0].retentionTier = .summary
        XCTAssertTrue(policy.containsRowsExcluded(in:transcript))
        XCTAssertFalse(policy.containsRowsExcluded(in:.empty))
    }
}
