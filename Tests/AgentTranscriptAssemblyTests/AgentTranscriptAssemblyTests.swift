import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptAssembly

final class AgentTranscriptAssemblyTests:XCTestCase {
    func testEmptyImportKeepsVersionAndExplicitSequenceWithoutCreatingProcessor() {
        var calls=0
        let service=assembly(makeProcessor:{calls+=1;return .init(execution:{_ in nil},normalizedName:{$0},sealsBoundary:{_,_ in false})})
        XCTAssertEqual(service.importLegacyItems([]),.init(version:3,turns:[],nextSequenceIndex:0))
        XCTAssertEqual(service.importLegacyItems([],nextSequenceIndex:77).nextSequenceIndex,77)
        XCTAssertEqual(calls,0)
    }
    func testImportOrdersBySequenceThenTimestampAndKeepsIdentifiers() {
        let user=row(0,kind:.user),late=row(1,text:"late",date:20)
        var early=row(2,text:"early",date:10);early.sequenceIndex=1
        let result=assembly().importLegacyItems([late,user,early])
        XCTAssertEqual(result.turns[0].id,user.id)
        XCTAssertEqual(result.turns[0].allActivities.map(\.text),["early","late"])
        XCTAssertEqual(result.nextSequenceIndex,2)
    }
    func testLeadingNonUserRowsHaveRequestlessTurnAndStableSpanID() {
        let item=row(1,kind:.system,text:"system")
        let result=assembly().importLegacyItems([item])
        XCTAssertNil(result.turns[0].request);XCTAssertEqual(result.turns[0].id,item.id)
        XCTAssertEqual(result.turns[0].responseSpans[0].id,AgentTranscriptIdentity.spanID(turnID:item.id,ordinal:0))
    }
    func testNewUserRowClosesPriorTurnAndKeepsTrailingActiveTurnOpen() {
        let result=assembly().importLegacyItems([row(0,kind:.user),row(1),row(2,kind:.user),row(3)],terminalState:.running)
        XCTAssertEqual(result.turns.count,2)
        XCTAssertNotNil(result.turns[0].completedAt);XCTAssertEqual(result.turns[0].responseSpans[0].lifecycle,.completed)
        XCTAssertNil(result.turns[1].completedAt);XCTAssertEqual(result.turns[1].responseSpans[0].lifecycle,.open)
        XCTAssertEqual(result.turns[1].terminalState,.running)
    }
    func testAllActiveStatesLeaveTrailingSpanOpen() {
        for state in [AgentSessionRunState.running,.waitingForUser,.waitingForQuestion,.waitingForApproval] {
            let result=assembly().importLegacyItems([row(0,kind:.user),row(1)],terminalState:state)
            XCTAssertNil(result.turns[0].completedAt);XCTAssertEqual(result.turns[0].responseSpans[0].lifecycle,.open)
        }
    }
    func testTerminalRunMetadataAndStoredDatesRemainStable() {
        for state in [AgentSessionRunState.idle,.completed,.failed,.cancelled] {
            let result=assembly().importLegacyItems([row(0,kind:.user),row(1,date:100)],terminalState:state)
            XCTAssertEqual(result.turns[0].terminalState,state)
            XCTAssertEqual(result.turns[0].completedAt,Date(timeIntervalSince1970:100))
            XCTAssertEqual(result.turns[0].responseSpans[0].lifecycle,.completed)
        }
    }
    func testMissingInvocationIDsPairLastPendingCallByNormalizedToolName() {
        let items=[row(0,kind:.user),row(1,kind:.toolCall,name:"READ"),row(2,kind:.toolCall,name:"read"),row(3,kind:.toolResult,name:"read"),row(4,kind:.toolResult,name:"READ")]
        let executions=assembly().importLegacyItems(items).turns[0].allActivities.compactMap(\.toolExecution)
        XCTAssertEqual(executions.map(\.stableExecutionID),[items[1].id.uuidString,items[2].id.uuidString,items[2].id.uuidString,items[1].id.uuidString])
    }
    func testExplicitInvocationIDsAreNeverRepairedByNamePairing() {
        let id=UUID(),other=UUID()
        let items=[row(0,kind:.user),row(1,kind:.toolCall,name:"read",invocation:id),row(2,kind:.toolResult,name:"read",invocation:other)]
        XCTAssertEqual(assembly().importLegacyItems(items).turns[0].allActivities.compactMap{$0.toolExecution?.stableExecutionID},[id.uuidString,other.uuidString])
    }
    func testPendingNameQueuesDoNotCrossUserTurnBoundary() {
        let call=row(1,kind:.toolCall,name:"read"),result=row(3,kind:.toolResult,name:"read")
        let transcript=assembly().importLegacyItems([row(0,kind:.user),call,row(2,kind:.user),result])
        XCTAssertEqual(transcript.turns[1].allActivities[0].toolExecution?.stableExecutionID,result.id.uuidString)
    }
    func testProcessingContextIsFreshForEveryImport() {
        var contexts=0
        let service=assembly(makeProcessor:{
            contexts+=1;var rowsSeen=0
            return .init(execution:{item in rowsSeen+=1;return .init(stableExecutionID:"row-\(rowsSeen)",toolName:item.toolName,invocationID:nil,argsJSON:nil,resultJSON:nil,toolIsError:nil,status:.success)},normalizedName:{$0},sealsBoundary:{_,_ in false})
        })
        let rows=[row(0,kind:.user),row(1,kind:.toolResult,name:"read")]
        let a=service.importLegacyItems(rows),b=service.importLegacyItems(rows)
        XCTAssertEqual(a,b);XCTAssertEqual(contexts,2)
        XCTAssertEqual(a.turns[0].allActivities[0].toolExecution?.stableExecutionID,"row-1")
    }
    func testConclusionMustBeDisplayableAssistantAfterLatestMiddleActivity() {
        let before=row(1,text:"before"),after=row(3,text:"short")
        let result=assembly().importLegacyItems([row(0,kind:.user),before,row(2,kind:.toolCall,name:"read"),after,row(4,text:"   ")])
        XCTAssertEqual(result.turns[0].conclusionActivityID,after.id)
    }
    func testNoTrailingAssistantProducesNoConclusion() {
        let result=assembly().importLegacyItems([row(0,kind:.user),row(1),row(2,kind:.toolResult,name:"read")])
        XCTAssertNil(result.turns[0].conclusionActivityID)
    }
    func testRoleAndBoundaryPolicyAreSeparateAndStreamingFlagsSurviveImport() {
        var item=row(1,kind:.toolCall,name:"seal");item.isStreaming=true
        let activity=assembly().importLegacyItems([row(0,kind:.user),item]).turns[0].allActivities[0]
        XCTAssertEqual(activity.role,.toolExecution);XCTAssertTrue(activity.sealsAssistantBoundary);XCTAssertTrue(activity.isStreaming)
    }
    func testFrozenAllocationIsInvokedOnlyForCompletedTurnWithPriorTurns() {
        var priorCounts:[Int]=[]
        let service=assembly(frozen:{_,prior in priorCounts.append(prior.count);return 3})
        let result=service.importLegacyItems([row(0,kind:.user),row(1),row(2,kind:.user),row(3)],terminalState:.running)
        XCTAssertEqual(priorCounts,[0]);XCTAssertEqual(result.turns[0].frozenDetailedToolTailLimit,3)
        XCTAssertNil(result.turns[1].frozenDetailedToolTailLimit)
    }
    func testExplicitNextSequenceIsPreservedWithoutReconciliation() {
        XCTAssertEqual(assembly().importLegacyItems([row(0,kind:.user),row(1)],nextSequenceIndex:99).nextSequenceIndex,99)
    }
    func testStableIdentityVectorsPreserveExistingHashAndDomainSeparation() {
        let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(AgentTranscriptIdentity.summaryID(for:id).uuidString,"EB2C8450-5768-3737-1D50-5EE8F892252D")
        XCTAssertEqual(AgentTranscriptIdentity.conclusionID(for:id).uuidString,"34EF6B33-8F72-E2F7-E637-72CA0B7F8D43")
        XCTAssertEqual(AgentTranscriptIdentity.spanID(turnID:id,ordinal:0).uuidString,"A401A26A-CAA3-172C-1EA2-6C17BE358760")
        XCTAssertEqual(AgentTranscriptIdentity.spanID(turnID:id,ordinal:1).uuidString,"059BA012-B63B-F85F-9D83-5E66EC54CF08")
    }
    func testAllNonUserKindsKeepExistingActivityRoles() {
        let kinds:[AgentChatItemKind]=[.assistant,.assistantInline,.toolCall,.toolResult,.system,.error,.thinking]
        let result=assembly().importLegacyItems([row(0,kind:.user)]+kinds.enumerated().map{row($0.offset+1,kind:$0.element)})
        XCTAssertEqual(result.turns[0].allActivities.map(\.role),[.assistant,.assistant,.toolExecution,.toolExecution,.system,.error,.thinking])
    }
    func testHostSummaryCallbacksObserveFinalConclusionAndClosedSpan() {
        var seenConclusions:[UUID?]=[];var lifecycles:[AgentTranscriptSpanLifecycle]=[]
        let services=AgentTranscriptAssemblyServices(makeToolProcessor:{.init(execution:{_ in nil},normalizedName:{$0},sealsBoundary:{_,_ in false})},
            summarizeTurn:{turn in seenConclusions.append(turn.conclusionActivityID);return nil},
            summarizeSpan:{span,turn in lifecycles.append(span.lifecycle);seenConclusions.append(turn.conclusionActivityID);return nil},frozenTailLimit:{_,_ in nil})
        let answer=row(1)
        _=AgentTranscriptAssemblyService(services:services).importLegacyItems([row(0,kind:.user),answer])
        XCTAssertEqual(lifecycles,[.completed]);XCTAssertEqual(seenConclusions,[answer.id,answer.id])
    }
    func testEquivalentRebuildsPreserveTranscriptAndAllStableIDs() {
        let rows=[row(0,kind:.user),row(1,kind:.toolCall,name:"read"),row(2,kind:.toolResult,name:"read"),row(3)]
        let service=assembly()
        XCTAssertEqual(service.importLegacyItems(rows),service.importLegacyItems(rows.reversed()))
    }

}
