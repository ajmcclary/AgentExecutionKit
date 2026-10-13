import XCTest
import Foundation
import AgentRuntimeKit
import AgentToolPersistence

final class AgentToolPersistenceTests: XCTestCase {
    func item(_ kind:AgentChatItemKind = .toolResult,_ text:String="raw",name:String?="READ",args:String?="args",result:String?="result")->AgentChatItem {
        .init(timestamp:Date(timeIntervalSince1970:10),kind:kind,text:text,toolName:name,toolArgsJSON:args,toolResultJSON:result,sequenceIndex:7)
    }
    func execution(_ item:AgentChatItem)->AgentTranscriptToolExecution {
        .init(stableExecutionID:item.id.uuidString,toolName:item.toolName,invocationID:item.toolInvocationID,argsJSON:item.toolArgsJSON,resultJSON:item.toolResultJSON,toolIsError:false,status:.pending,keyPaths:["original"])
    }
    func summary(_ text:String="safe",status:AgentTranscriptToolStatus = .failed,raw:Bool=false)->AgentSanitizedToolResult {
        .init(text:text,resultJSON:"safe-json",toolIsError:true,persistedStatusWord:"host-status",transcriptStatus:status,summaryOnly:true,processID:"pid",exitCode:9,preservesRawPayload:raw)
    }
    func services()->AgentToolPersistenceServices {
        .init(execution:{self.execution($0)},visibleName:{$0?.lowercased()},pathSignal:{_ in "path"},storeExecution:{_,_ in},runtimeSummary:{_,_ in self.summary()},persistedSummary:{_,_,_ in .init(resultJSON:"persisted",statusWord:"host-failed",transcriptStatus:.failed,toolIsError:true,processID:"proc",exitCode:2,summaryText:"subtitle",summaryOnly:false)},storagePresentation:{_,_,_ in .init(resultJSON:"fallback",summaryText:"fallback-summary")},callSummary:{_,_,_ in "call-summary"},fallbackJSON:{status,_,pid,_,summary in "minimal-\(status.rawValue)-\(pid ?? "nil")-\(summary ?? "nil")"})
    }
    func transcript(_ rows:[AgentChatItem],tier:AgentTranscriptRetentionTier = .full,executions:Bool=true,cache:Bool=false)->AgentTranscript {
        var span=AgentTranscriptProviderResponseSpan(startedAt:Date(timeIntervalSince1970:10),activities:rows.map{AgentTranscriptActivity(from:$0,toolExecution:executions ? execution($0) : nil)})
        if cache {span.fullRenderGroupedHistoryCache = .init(detailedToolTailLimit:3,collapseDigest:"cache",summary:.init(hiddenToolCardCount:1,hiddenAssistantCount:0,hiddenProgressCount:0,hiddenNoteCount:0,toolSummary:nil))}
        return .init(turns:[.init(responseSpans:[span],retentionTier:tier,startedAt:Date(timeIntervalSince1970:10))])
    }
    func run(_ input:AgentTranscript,ports:AgentToolPersistenceServices?=nil,purpose:AgentToolResultSanitizationPurpose = .runtimePresentation,preserve:Set<UUID>=[])->AgentSanitizedTranscriptMetrics {
        AgentToolPersistenceService(services:ports ?? services()).sanitizeTranscriptWithMetrics(input,preservedVisibleToolResultRowIDs:preserve,purpose:purpose)
    }
    func activity(_ result:AgentSanitizedTranscriptMetrics)->AgentTranscriptActivity {result.transcript.turns[0].allActivities[0]}
    func testEmptyTranscriptMakesNoCalls() {
        var p=services();p.execution={_ in XCTFail("unexpected call");return nil}
        XCTAssertEqual(run(.empty,ports:p).transcript,.empty);XCTAssertEqual(run(.empty,ports:p).sanitizedActivityCount,0)
    }
    func testRuntimeCallOnlyTranscriptIsUnchangedIncludingIdentity() {
        let input=transcript([item(.toolCall)],cache:true);XCTAssertEqual(run(input).transcript,input)
    }
    func testPersistentCallOnlyTranscriptIsProcessed() {
        let result=run(transcript([item(.toolCall)]),purpose:.persistentStorage),a=activity(result)
        XCTAssertEqual(a.text,"Using tool: read");XCTAssertNil(a.toolExecution?.argsJSON);XCTAssertNil(a.toolExecution?.resultJSON);XCTAssertEqual(a.toolExecution?.keyPaths,[]);XCTAssertEqual(a.toolExecution?.summaryOnly,true);XCTAssertEqual(a.toolExecution?.status,.pending)
    }
    func testRuntimeSummaryUpdatesTypedFieldsWithoutErasingArgsOrPaths() {
        let input=transcript([item()]),a=activity(run(input))
        XCTAssertEqual(a.text,"safe");XCTAssertEqual(a.toolExecution?.resultJSON,"safe-json");XCTAssertEqual(a.toolExecution?.status,.failed);XCTAssertEqual(a.toolExecution?.toolIsError,true);XCTAssertEqual(a.toolExecution?.processID,"pid");XCTAssertEqual(a.toolExecution?.exitCode,9);XCTAssertEqual(a.toolExecution?.argsJSON,"args");XCTAssertEqual(a.toolExecution?.keyPaths,["path","original"])
    }
    func testRuntimePreservedRowSkipsSummaryButNormalizesIdentity() {
        let row=item();var p=services();p.runtimeSummary={_,_ in XCTFail("preserved result");return nil}
        let a=activity(run(transcript([row]),ports:p,preserve:[row.id]));XCTAssertEqual(a.text,"raw");XCTAssertEqual(a.toolExecution?.toolName,"read");XCTAssertEqual(a.toolExecution?.resultJSON,"result")
    }
    func testPersistenceIgnoresVisibleRowExemption() {
        let row=item();let a=activity(run(transcript([row]),purpose:.persistentStorage,preserve:[row.id]));XCTAssertEqual(a.text,"persisted");XCTAssertNil(a.toolExecution?.argsJSON)
    }
    func testPersistentSummaryPreservesCompletionAndSummaryOnlyChoice() {
        let a=activity(run(transcript([item()]),purpose:.persistentStorage));XCTAssertEqual(a.toolExecution?.status,.failed);XCTAssertEqual(a.toolExecution?.toolIsError,true);XCTAssertEqual(a.toolExecution?.summaryOnly,false);XCTAssertEqual(a.toolExecution?.processID,"proc");XCTAssertEqual(a.toolExecution?.exitCode,2);XCTAssertEqual(a.toolExecution?.summaryText,"subtitle");XCTAssertEqual(a.toolExecution?.keyPaths,[])
    }
    func testPersistentFallbackUsesHostPresentationAndRetainsExistingStatus() {
        var p=services();p.persistedSummary={_,_,_ in nil};let a=activity(run(transcript([item()]),ports:p,purpose:.persistentStorage));XCTAssertEqual(a.text,"fallback");XCTAssertEqual(a.toolExecution?.summaryText,"fallback-summary");XCTAssertEqual(a.toolExecution?.status,.pending);XCTAssertEqual(a.toolExecution?.summaryOnly,true)
    }
    func testGeneratedExecutionUsesOriginalRowIdentityAndTimestamp() {
        let row=item(),input=transcript([row],executions:false),a=activity(run(input));XCTAssertEqual(a.id,row.id);XCTAssertEqual(a.timestamp,row.timestamp);XCTAssertEqual(a.sequenceIndex,7);XCTAssertEqual(a.toolExecution?.stableExecutionID,row.id.uuidString)
    }
    func testMissingExecutionLeavesActivityUnchanged() {
        var p=services();p.execution={_ in nil};let input=transcript([item()],executions:false);XCTAssertEqual(run(input,ports:p).transcript,input);XCTAssertEqual(run(input,ports:p).sanitizedActivityCount,0)
    }
    func testMissingSummaryStillAllowsIdentityNormalization() {
        var p=services();p.runtimeSummary={_,_ in nil};let a=activity(run(transcript([item()]),ports:p));XCTAssertEqual(a.text,"raw");XCTAssertEqual(a.toolExecution?.toolName,"read")
    }
    func testNonToolWithExecutionIsSanitizedOnlyForStorage() {
        let input=transcript([item(.system)]);XCTAssertEqual(run(input).transcript,input);let a=activity(run(input,purpose:.persistentStorage));XCTAssertNil(a.toolExecution?.argsJSON);XCTAssertEqual(a.text,"Using tool: READ")
    }
    func testMissingAndEmptyNamesDoNotEraseExistingIdentity() {
        for name:String? in [nil,""] {var p=services();p.visibleName={_ in name};p.pathSignal={_ in nil};let a=activity(run(transcript([item()]),ports:p));XCTAssertEqual(a.toolExecution?.toolName,"READ")}
    }
    func testPathSignalDoesNotDuplicateExistingPath() {
        var input=transcript([item()]);input.turns[0].responseSpans[0].activities[0].toolExecution?.keyPaths=["path"]
        XCTAssertEqual(activity(run(input)).toolExecution?.keyPaths,["path"])
    }
    func testCacheInvalidatesOnlyMutatedSpan() {
        let input=transcript([item()],cache:true);XCTAssertNil(run(input).transcript.turns[0].responseSpans[0].fullRenderGroupedHistoryCache)
        var p=services();p.visibleName={$0};p.pathSignal={_ in nil};p.runtimeSummary={_,_ in nil};XCTAssertEqual(run(input,ports:p).transcript,input)
    }
    func testEachChangedActivityIsCountedOnceForNormalizationAndSummary() {
        XCTAssertEqual(run(transcript([item(),item()])).sanitizedActivityCount,2)
    }
    func testRuntimeSummaryCountsSuccessfulProcessingEvenIfBytesAreIdentical() {
        var p=services();p.visibleName={$0};p.pathSignal={_ in nil};var input=transcript([item()]);let a=input.turns[0].responseSpans[0].activities[0];let e=a.toolExecution!;p.runtimeSummary={_,_ in .init(text:a.text,resultJSON:e.resultJSON,toolIsError:e.toolIsError,persistedStatusWord:"pending",transcriptStatus:e.status,summaryOnly:e.summaryOnly,processID:e.processID,exitCode:e.exitCode,preservesRawPayload:true)}
        input.turns[0].responseSpans[0].activities[0]=a;XCTAssertEqual(run(input,ports:p).sanitizedActivityCount,1)
    }
    func testStoreCallbackRunsBeforeSummaryThenAfterUpdate() {
        var events:[String]=[];var p=services();p.storeExecution={e,_ in events.append(e.resultJSON ?? "nil")};p.runtimeSummary={_,_ in events.append("summary");return self.summary()};_ = run(transcript([item()]),ports:p);XCTAssertEqual(events,["result","summary","safe-json"])
    }
    func testFrozenEqualPrefixReusesAndOnlyProcessesTail() {
        let frozen=transcript([item()],tier:.summary);let tail=transcript([item()]);let input=AgentTranscript(turns:frozen.turns+tail.turns)
        let result=AgentToolPersistenceService(services:services()).sanitizeTranscriptWithMetrics(input,previousSanitizedTranscript:input)
        XCTAssertEqual(result.reusedTurnCount,1);XCTAssertEqual(result.sanitizedActivityCount,1);XCTAssertEqual(result.transcript.turns[0],input.turns[0])
    }
    func testFullOrChangedPrefixCannotBeReused() {
        let input=transcript([item()]);let service=AgentToolPersistenceService(services:services());XCTAssertEqual(service.sanitizeTranscriptWithMetrics(input,previousSanitizedTranscript:input).reusedTurnCount,0)
        let frozen=transcript([item()],tier:.summary);var previous=frozen;previous.turns[0].lastActivityAt=Date(timeIntervalSince1970:20);XCTAssertEqual(service.sanitizeTranscriptWithMetrics(frozen,previousSanitizedTranscript:previous).reusedTurnCount,0)
    }
    func testRequestedReuseLimitsAreClampedAndNegativeMeansNone() {
        let input=transcript([item()],tier:.summary),service=AgentToolPersistenceService(services:services())
        XCTAssertEqual(service.sanitizeTranscriptWithMetrics(input,previousSanitizedTranscript:input,reusablePrefixTurnCount:100).reusedTurnCount,1)
        for count in [0,-1] {XCTAssertEqual(service.sanitizeTranscriptWithMetrics(input,previousSanitizedTranscript:input,reusablePrefixTurnCount:count).reusedTurnCount,0)}
    }
    func testPersistenceNeverReusesRuntimePrefix() {
        let input=transcript([item()],tier:.summary);let result=AgentToolPersistenceService(services:services()).sanitizeTranscriptWithMetrics(input,previousSanitizedTranscript:input,purpose:.persistentStorage);XCTAssertEqual(result.reusedTurnCount,0);XCTAssertEqual(activity(result).text,"persisted")
    }
    func testOversizedPersistedResultAndActivityAreCappedTogether() {
        var p=services();p.persistedSummary={_,_,_ in .init(resultJSON:String(repeating:"é",count:1025),statusWord:"failed",transcriptStatus:.failed,toolIsError:true,processID:"pid",exitCode:2,summaryText:"summary",summaryOnly:true)};let a=activity(run(transcript([item()]),ports:p,purpose:.persistentStorage));XCTAssertEqual(a.text,a.toolExecution?.resultJSON);XCTAssertTrue(a.text.hasPrefix("minimal-failed"));XCTAssertLessThanOrEqual(a.text.utf8.count,2048)
    }
    func testExactByteBudgetIsRetained() {
        var p=services();p.persistedSummary={_,_,_ in .init(resultJSON:String(repeating:"é",count:1024),statusWord:"pending",transcriptStatus:.pending,toolIsError:nil,processID:nil,exitCode:nil,summaryText:"s",summaryOnly:true)};XCTAssertEqual(activity(run(transcript([item()]),ports:p,purpose:.persistentStorage)).text.utf8.count,2048)
    }
    func testOversizedMetadataFallbackIsRetriedWithoutMetadata() {
        var calls:[Bool]=[];var p=services();p.fallbackJSON={_,_,pid,_,summary in calls.append(pid != nil || summary != nil);return pid != nil || summary != nil ? String(repeating:"x",count:2049) : "minimal"};_ = run(transcript([item()]),ports:p,purpose:.persistentStorage);XCTAssertEqual(calls,[true,false])
    }
    func testMetadataUsesUTF8ByteLimitAndDropsOversizeRatherThanTruncating() {
        XCTAssertEqual(AgentToolPersistenceService.storageSafeMetadataString(String(repeating:"é",count:256))?.utf8.count,512);XCTAssertNil(AgentToolPersistenceService.storageSafeMetadataString(String(repeating:"é",count:257)));XCTAssertNil(AgentToolPersistenceService.storageSafeMetadataString(" \n"));XCTAssertEqual(AgentToolPersistenceService.storageSafeMetadataString(" pid \n"),"pid")
    }
    func testOversizedToolNameUsesSafeNormalizedNameOrGenericFallback() {
        let input=transcript([item(name:String(repeating:"x",count:513))]);var p=services();p.visibleName={_ in "safe"};XCTAssertEqual(activity(run(input,ports:p,purpose:.persistentStorage)).toolExecution?.toolName,"safe")
        p.visibleName={$0};XCTAssertEqual(activity(run(input,ports:p,purpose:.persistentStorage)).toolExecution?.toolName,"tool")
    }
    func testSummaryCompactionUsesCharacterLimitAndLegacyEllipsis() {
        XCTAssertNil(AgentToolPersistenceService.smallStorageSummaryText(nil));XCTAssertEqual(AgentToolPersistenceService.smallStorageSummaryText(String(repeating:"é",count:240)),String(repeating:"é",count:240));XCTAssertEqual(AgentToolPersistenceService.smallStorageSummaryText(String(repeating:"é",count:241)),String(repeating:"é",count:237)+"…")
    }
    func testSanitizeItemTouchesOnlyLegacyResultFields() {
        let row=item();let result=AgentToolPersistenceService(services:services()).sanitizeItem(row);XCTAssertEqual(result.id,row.id);XCTAssertEqual(result.timestamp,row.timestamp);XCTAssertEqual(result.toolArgsJSON,row.toolArgsJSON);XCTAssertEqual(result.text,"safe");XCTAssertEqual(result.toolIsError,true)
    }
    func testEphemeralRawRetentionDecisionIsPreserved() {
        XCTAssertTrue(summary().shouldRetainEphemeralRawPayload);XCTAssertFalse(summary(raw:true).shouldRetainEphemeralRawPayload)
    }
    func testMultipleSpansInvalidateOnlyTheChangedCacheAndPreserveTurnEnvelope() {
        var input=transcript([item()],cache:true);let other=transcript([item(.assistant)],executions:false,cache:true)
        input.turns[0].responseSpans.append(other.turns[0].responseSpans[0]);input.turns[0].request = .init(from:item(.user,"request"));input.turns[0].terminalState = .running;input.nextSequenceIndex=99
        let result=run(input)
        XCTAssertNil(result.transcript.turns[0].responseSpans[0].fullRenderGroupedHistoryCache)
        XCTAssertEqual(result.transcript.turns[0].responseSpans[1],input.turns[0].responseSpans[1]);XCTAssertEqual(result.transcript.turns[0].request,input.turns[0].request);XCTAssertEqual(result.transcript.turns[0].terminalState,.running);XCTAssertEqual(result.transcript.nextSequenceIndex,99);XCTAssertEqual(result.transcript.version,input.version)
    }
    func testStoredTranscriptDoesNotReintroduceRawPayloadOnRepeatedPersistence() {
        let once=run(transcript([item()]),purpose:.persistentStorage).transcript
        let twice=run(once,purpose:.persistentStorage).transcript
        XCTAssertEqual(twice,once);XCTAssertNil(twice.turns[0].allActivities[0].toolExecution?.argsJSON);XCTAssertFalse(twice.turns[0].allActivities[0].text.contains("raw"))
    }

}
