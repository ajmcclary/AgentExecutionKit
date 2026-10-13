import Foundation
import XCTest
import AgentRuntimeKit
import AgentToolPersistence
import AgentTranscriptMaterialization
import AgentTranscriptPersistence

struct Projection: Sendable, Equatable {let value:Int;let visible:Set<UUID>}
final class MaterializationTests:XCTestCase {
    let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    let other=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
    func input()->AgentTranscript {
        .init(turns:[.init(id:id,request:.init(from:.init(id:id,timestamp:Date(timeIntervalSince1970:10),kind:.user,text:"request",sequenceIndex:1)),startedAt:Date(timeIntervalSince1970:10)),.init(id:other,startedAt:Date(timeIntervalSince1970:20))],nextSequenceIndex:30,compactionFrontier:.init(frozenPrefixTurnCount:1,lastFrozenTurnID:id))
    }
    func ports()->AgentTranscriptMaterializationServices<Projection> {
        .init(compact:{t,_ in t},truncateTranscript:{$0},truncateExportSlice:{$0},sanitizeRuntime:{t,_ in .init(transcript:t,sanitizedActivityCount:7,reusedTurnCount:1)},sanitizeStorage:{t in .init(transcript:t,sanitizedActivityCount:9,reusedTurnCount:0)},refreshCaches:{$0},project:{.init(value:$0.nextSequenceIndex,visible:[])},visibleToolResultRowIDs:{$0.visible},retainedFullDetailBytes:{$0.nextSequenceIndex})
    }
    func testEmptyRuntimeHasOneSanitizationAndRefresh() {
        var runtime=0,refresh=0;var p=ports();p.sanitizeRuntime={t,_ in runtime+=1;return .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)};p.refreshCaches={t in refresh+=1;return t}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(.empty)
        XCTAssertEqual(runtime,1);XCTAssertEqual(refresh,1);XCTAssertEqual(result.transcript,.empty)
    }
    func testRuntimeOrderingAndStableVisibilityShortCircuit() {
        var events:[String]=[];var p=ports();p.project={t in events.append("project");return .init(value:t.nextSequenceIndex,visible:[self.id])};p.visibleToolResultRowIDs={v in events.append("visible");return v.visible};p.sanitizeRuntime={t,visible in events.append("runtime");XCTAssertEqual(visible,[self.id]);return .init(transcript:t,sanitizedActivityCount:7,reusedTurnCount:1)};p.refreshCaches={t in events.append("refresh");return t};p.retainedFullDetailBytes={_ in events.append("bytes");return 99}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(input())
        XCTAssertEqual(events,["project","visible","runtime","refresh","project","visible","bytes"]);XCTAssertEqual(result.visibleToolResultRowIDs,[id]);XCTAssertEqual(result.retainedFullDetailBytes,99)
    }
    func testOneVisibilityChangeRetriesOriginalInput() {
        let original=input();var passes=0,projects=0,seen:[AgentTranscript]=[],sets:[Set<UUID>]=[];var p=ports()
        p.project={t in projects+=1;return .init(value:t.nextSequenceIndex,visible:projects==1 ? []:[self.id])}
        p.sanitizeRuntime={t,v in seen.append(t);sets.append(v);passes+=1;var copy=t;copy.nextSequenceIndex+=passes;return .init(transcript:copy,sanitizedActivityCount:passes,reusedTurnCount:0)}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(original)
        XCTAssertEqual(seen,[original,original]);XCTAssertEqual(sets,[[],[id]]);XCTAssertEqual(projects,3);XCTAssertEqual(result.sanitizedActivityCount,2);XCTAssertEqual(result.transcript.nextSequenceIndex,32)
    }
    func testThreeVisibilityChangesUseBoundedFourSanitizationsAndFiveProjections() {
        var projects=0,passes=0,visibleReads=0;var p=ports()
        p.project={_ in projects+=1;return .init(value:projects,visible:projects%2==0 ? [self.id]:[self.other])}
        p.visibleToolResultRowIDs={v in visibleReads+=1;return v.visible}
        p.sanitizeRuntime={t,_ in passes+=1;return .init(transcript:t,sanitizedActivityCount:passes,reusedTurnCount:0)}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(input())
        XCTAssertEqual(passes,4);XCTAssertEqual(projects,5);XCTAssertEqual(visibleReads,4);XCTAssertEqual(result.projection.value,5);XCTAssertEqual(result.sanitizedActivityCount,4)
        // Legacy capped output reports the IDs used for the last sanitation, even
        // when the newest projection would change visibility again.
        XCTAssertEqual(result.visibleToolResultRowIDs,[id]);XCTAssertEqual(result.projection.visible,[other])
    }
    func testConvergenceOnLastAllowedObservationDoesNotAddAnotherPass() {
        var projects=0,passes=0;var p=ports();p.project={_ in projects+=1;return .init(value:projects,visible:projects==1 ? []:projects==2 ? [self.id]:[self.other])};p.sanitizeRuntime={t,_ in passes+=1;return .init(transcript:t,sanitizedActivityCount:passes,reusedTurnCount:0)}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(input());XCTAssertEqual(passes,3);XCTAssertEqual(projects,4);XCTAssertEqual(result.visibleToolResultRowIDs,[other])
    }
    func testCacheRefreshPrecedesProjectionAndFinalByteAccounting() {
        var p=ports();p.refreshCaches={t in var copy=t;copy.nextSequenceIndex=555;return copy}
        let result=AgentTranscriptMaterializationService(services:p).runtimeTranscript(input());XCTAssertEqual(result.projection.value,555);XCTAssertEqual(result.retainedFullDetailBytes,555);XCTAssertEqual(result.sanitizedActivityCount,7)
    }
    func testRuntimeNeverCompactsTruncatesOrUsesStorageSanitizer() {
        var p=ports();p.compact={t,_ in XCTFail("compact");return t};p.truncateTranscript={t in XCTFail("truncate");return t};p.truncateExportSlice={t in XCTFail("slice");return t};p.sanitizeStorage={t in XCTFail("storage");return .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)}
        XCTAssertEqual(AgentTranscriptMaterializationService(services:p).runtimeTranscript(input()).transcript,input())
    }
    func testStoredNormalizationOrderAndProtectedIdentity() {
        var events:[String]=[];var p=ports();p.compact={t,protected in events.append("compact");XCTAssertEqual(protected,self.other);var c=t;c.nextSequenceIndex=40;return c};p.truncateTranscript={t in events.append("truncate");XCTAssertEqual(t.nextSequenceIndex,40);var c=t;c.nextSequenceIndex=50;return c};p.sanitizeStorage={t in events.append("storage");XCTAssertEqual(t.nextSequenceIndex,50);return .init(transcript:t,sanitizedActivityCount:9,reusedTurnCount:0)};p.refreshCaches={t in events.append("refresh");return t};p.project={t in events.append("project");return .init(value:t.nextSequenceIndex,visible:[self.id])};p.visibleToolResultRowIDs={v in events.append("visible");return v.visible};p.retainedFullDetailBytes={t in events.append("bytes");return t.nextSequenceIndex}
        let result=AgentTranscriptMaterializationService(services:p).persistedTranscript(from:input(),protectedTurnID:other)
        XCTAssertEqual(events,["compact","truncate","storage","refresh","project","visible","bytes"]);XCTAssertEqual(result.retainedFullDetailBytes,50);XCTAssertEqual(result.sanitizedActivityCount,9)
    }
    func testDefaultStoredProtectionIsNil() {
        var p=ports();p.compact={t,protected in XCTAssertNil(protected);return t};_ = AgentTranscriptMaterializationService(services:p).persistedTranscript(from:input())
    }
    func testAlreadyNormalizedStorageDoesNotCompact() {
        var p=ports();p.compact={t,_ in XCTFail("compact");return t};XCTAssertEqual(AgentTranscriptMaterializationService(services:p).persistedNormalizedTranscript(input()).sanitizedActivityCount,9)
    }
    func testStorageMakesOneProjectionAndNoRuntimePassOrVisibilityRetry() {
        var projects=0,reads=0;var p=ports();p.sanitizeRuntime={t,_ in XCTFail("runtime");return .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)};p.project={t in projects+=1;return .init(value:t.nextSequenceIndex,visible:[self.id])};p.visibleToolResultRowIDs={v in reads+=1;return v.visible};_ = AgentTranscriptMaterializationService(services:p).persistedNormalizedTranscript(input());XCTAssertEqual(projects,1);XCTAssertEqual(reads,1)
    }
    func testStorageProjectionUsesRefreshedSanitizedValue() {
        var p=ports();p.sanitizeStorage={t in var c=t;c.nextSequenceIndex=111;return .init(transcript:c,sanitizedActivityCount:3,reusedTurnCount:1)};p.refreshCaches={t in XCTAssertEqual(t.nextSequenceIndex,111);var c=t;c.nextSequenceIndex=222;return c}
        let result=AgentTranscriptMaterializationService(services:p).persistedNormalizedTranscript(input());XCTAssertEqual(result.projection.value,222);XCTAssertEqual(result.transcript.nextSequenceIndex,222);XCTAssertEqual(result.sanitizedActivityCount,3)
    }
    func testHandoffSlicesBeforeHistoricalPolicyAndClearsFrontier() {
        var seen:[UUID]=[];var p=ports();p.truncateExportSlice={turns in seen=turns.map(\.id);return turns};let result=AgentTranscriptMaterializationService(services:p).handoffTranscript(from:input(),upToRowID:id)
        XCTAssertEqual(seen,[id]);XCTAssertEqual(result.transcript.turns.map(\.id),[id]);XCTAssertNil(result.transcript.compactionFrontier);XCTAssertEqual(result.transcript.version,3);XCTAssertEqual(result.transcript.nextSequenceIndex,30)
    }
    func testHandoffUnknownOrNilCutoffRetainsAllTurnsButClearsFrontier() {
        let service=AgentTranscriptMaterializationService(services:ports());for cutoff:UUID? in [nil,UUID()] {let result=service.handoffTranscript(from:input(),upToRowID:cutoff);XCTAssertEqual(result.transcript.turns,input().turns);XCTAssertNil(result.transcript.compactionFrontier)}
    }
    func testHandoffUsesRuntimeOnlyWithoutStorageCompaction() {
        var p=ports();p.compact={t,_ in XCTFail("compact");return t};p.truncateTranscript={t in XCTFail("whole truncation");return t};p.sanitizeStorage={t in XCTFail("storage");return .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)};_ = AgentTranscriptMaterializationService(services:p).handoffTranscript(from:input(),upToRowID:id)
    }
    func testHistoricalPolicyIsRelativeToHandoffSlice() {
        var t=input();t.turns += [.init(startedAt:Date(timeIntervalSince1970:30))];t.turns[0].request?.text=String(repeating:"x",count:100)
        var p=ports();let policy=AgentTranscriptHistoricalTextPolicy{text,_,_ in String(text.prefix(5))};p.truncateExportSlice={policy.truncatedExportSlice($0,exemptTurnCount:1)}
        let result=AgentTranscriptMaterializationService(services:p).handoffTranscript(from:t,upToRowID:id);XCTAssertEqual(result.transcript.turns[0].request?.text,String(repeating:"x",count:100))
    }
    func testRuntimePreservesEnvelopeAndFrontierWithoutMutationPolicy() {
        let t=input();XCTAssertEqual(AgentTranscriptMaterializationService(services:ports()).runtimeTranscript(t).transcript,t)
    }
    func testDifferentProjectionTypesRemainCallerOwned() {
        final class ReferenceProjection {let count:Int;init(_ count:Int){self.count=count}}
        let p=AgentTranscriptMaterializationServices<ReferenceProjection>(compact:{t,_ in t},truncateTranscript:{$0},truncateExportSlice:{$0},sanitizeRuntime:{t,_ in .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)},sanitizeStorage:{t in .init(transcript:t,sanitizedActivityCount:0,reusedTurnCount:0)},refreshCaches:{$0},project:{ReferenceProjection($0.turns.count)},visibleToolResultRowIDs:{_ in []},retainedFullDetailBytes:{_ in 0})
        XCTAssertEqual(AgentTranscriptMaterializationService(services:p).runtimeTranscript(input()).projection.count,2)
    }
    func testValueProjectionProducesSendableResult() {
        func accept<T:Sendable>(_ value:T) {}
        accept(AgentTranscriptMaterializationService(services:ports()).runtimeTranscript(input()))
    }
    func testFinalMetricsBelongToLastPassRatherThanSumOfPasses() {
        var projects=0,pass=0;var p=ports();p.project={t in projects+=1;return .init(value:t.nextSequenceIndex,visible:projects==1 ? []:[self.id])};p.sanitizeRuntime={t,_ in pass+=1;return .init(transcript:t,sanitizedActivityCount:pass*10,reusedTurnCount:0)}
        XCTAssertEqual(AgentTranscriptMaterializationService(services:p).runtimeTranscript(input()).sanitizedActivityCount,20)
    }
}
