import XCTest
import Foundation
import AgentRuntimeKit
import AgentUsage
import AgentSessionContracts

final class AgentSessionContractsTests:XCTestCase {
    private let id=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!
    private let date=Date(timeIntervalSinceReferenceDate:0)
    private var minimal:String { "{\"id\":\"\(id.uuidString)\",\"name\":\"session\",\"savedAt\":0,\"autoEditEnabled\":true}" }
    private func decode(_ json:String) throws -> AgentSession { try JSONDecoder().decode(AgentSession.self,from:Data(json.utf8)) }
    private func object(_ session:AgentSession) throws -> [String:Any] { try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(session)) as? [String:Any]) }
    private func full() -> AgentSession {
        let row=AgentChatItemPersist(id:id,timestamp:date,kind:.user,text:"user",attachments:[.init(id:id,source:.url("https://example.com/image.png"),createdAt:date)],taggedFileAttachments:[],toolName:nil,toolInvocationID:nil,toolArgsJSON:nil,toolResultJSON:nil,toolIsError:nil,toolResultStatus:nil,reasoning:nil,sequenceIndex:0,workflow:nil,codexGoalMode:nil,isLocalControlPlaneEcho:false)
        return .init(id:id,workspaceID:id,composeTabID:id,name:"  raw\nname  ",savedAt:date,fileURL:URL(fileURLWithPath:"/host/sessions/file.json"),items:[row],transcript:.init(version:3,nextSequenceIndex:99),itemCount:7,
            transcriptProjectionCounts:.init(canonicalVisibleRowCount:7,defaultPresentedRowCount:4),lastUserMessageAt:date,agentKind:"future-provider",agentModel:"custom/model\nraw",agentReasoningEffort:"future-effort",lastRunState:"future-state",providerSessionID:"raw/provider/session",geminiACPResumeMetadata:.init(runtimeSessionID:"runtime/raw",loadSessionID:"load/raw",loadSessionIDVerifiedAt:date),autoEditEnabled:false,
            providerTokenUsageByTurn:[.init(promptTokens:7,completionTokens:3,timestamp:date)],codexConversationID:"thread/raw",codexRolloutPath:"/host/rollout",codexModel:"raw/model",codexReasoningEffort:"future",codexServiceTier:"future-tier",codexContextWindow:1000,codexLastTotalTokens:7,codexTotalTotalTokens:30,codexMcpSessionKey:"mcp/raw",parentSessionID:id,pendingHandoffPayload:"handoff\nraw",pendingHandoffCreatedAt:date,pendingHandoffSourceItemID:id,pendingHandoffDefersProviderLockUntilSend:true,isMCPOriginated:true)
    }
    func testLegacyMinimalDecodeRetainsVersionZeroAndOptionalDefaults() throws {
        let s=try decode(minimal)
        XCTAssertEqual(s.serializationVersion,0);XCTAssertEqual(AgentSession.currentSerializationVersion,4)
        XCTAssertEqual(s.id,id);XCTAssertEqual(s.savedAt,date);XCTAssertEqual(s.name,"session")
        XCTAssertTrue(s.items.isEmpty);XCTAssertNil(s.transcript);XCTAssertTrue(s.providerTokenUsageByTurn.isEmpty)
        XCTAssertNil(s.geminiACPResumeMetadata);XCTAssertFalse(s.isMCPOriginated);XCTAssertFalse(s.pendingHandoffDefersProviderLockUntilSend)
    }
    func testDefaultConstructionUsesCurrentVersionAndExistingFlags() {
        let s=AgentSession(id:id,savedAt:date)
        XCTAssertEqual(s.serializationVersion,4);XCTAssertEqual(s.name,"Agent Session")
        XCTAssertTrue(s.autoEditEnabled);XCTAssertFalse(s.isMCPOriginated);XCTAssertFalse(s.pendingHandoffDefersProviderLockUntilSend)
    }
    func testCurrentFullEnvelopePreservesExactFieldSet() throws {
        let keys:Set<String>=["id","serializationVersion","workspaceID","composeTabID","name","savedAt","fileURL","items","transcript","itemCount","transcriptProjectionCounts","lastUserMessageAt","agentKind","agentModel","agentReasoningEffort","lastRunState","providerSessionID","geminiACPResumeMetadata","autoEditEnabled","providerTokenUsageByTurn","codexConversationID","codexRolloutPath","codexModel","codexReasoningEffort","codexServiceTier","codexContextWindow","codexLastTotalTokens","codexTotalTotalTokens","codexMcpSessionKey","parentSessionID","pendingHandoffPayload","pendingHandoffCreatedAt","pendingHandoffSourceItemID","pendingHandoffDefersProviderLockUntilSend","isMCPOriginated"]
        XCTAssertEqual(Set(try object(full()).keys),keys)
    }
    func testFullEnvelopeRoundTripIsCanonicalByteEquivalent() throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let first=try encoder.encode(full())
        let decoded=try JSONDecoder().decode(AgentSession.self,from:first)
        XCTAssertEqual(try encoder.encode(decoded),first)
    }
    func testOpaqueProviderModelResumeAndHandoffFieldsAreNeverReconciledByCodec() throws {
        let s=try JSONDecoder().decode(AgentSession.self,from:JSONEncoder().encode(full()))
        XCTAssertEqual(s.agentKind,"future-provider");XCTAssertEqual(s.agentModel,"custom/model\nraw")
        XCTAssertEqual(s.agentReasoningEffort,"future-effort");XCTAssertEqual(s.lastRunState,"future-state")
        XCTAssertEqual(s.providerSessionID,"raw/provider/session");XCTAssertEqual(s.geminiACPResumeMetadata?.loadSessionID,"load/raw")
        XCTAssertEqual(s.codexServiceTier,"future-tier");XCTAssertEqual(s.codexMcpSessionKey,"mcp/raw")
        XCTAssertEqual(s.pendingHandoffPayload,"handoff\nraw");XCTAssertTrue(s.isMCPOriginated)
    }
    func testUnknownExtraFieldsAreIgnoredWithoutChangingKnownValues() throws {
        let json=minimal.dropLast()+",\"future\":{\"revision\":99}}"
        let s=try decode(String(json))
        XCTAssertEqual(s.id,id);XCTAssertEqual(s.name,"session");XCTAssertEqual(s.serializationVersion,0)
        XCTAssertNil(try object(s)["future"])
    }
    func testFutureAndNegativeSerializationVersionsArePreservedForHostPolicy() throws {
        for version in [99,-1] {
            let s=try decode(String(minimal.dropLast())+",\"serializationVersion\":\(version)}")
            XCTAssertEqual(s.serializationVersion,version)
            XCTAssertEqual(try object(s)["serializationVersion"] as? Int,version)
        }
    }
    func testNullVersionKeepsLegacyUnversionedSemantics() throws {
        XCTAssertEqual(try decode(String(minimal.dropLast())+",\"serializationVersion\":null}").serializationVersion,0)
    }
    func testAbsentAndNullCollectionsRemainEmptyAndOptionalFlagsDefaultFalse() throws {
        let s=try decode(String(minimal.dropLast())+",\"items\":null,\"transcript\":null,\"providerTokenUsageByTurn\":null,\"pendingHandoffDefersProviderLockUntilSend\":null,\"isMCPOriginated\":null}")
        XCTAssertTrue(s.items.isEmpty);XCTAssertNil(s.transcript);XCTAssertTrue(s.providerTokenUsageByTurn.isEmpty)
        XCTAssertFalse(s.pendingHandoffDefersProviderLockUntilSend);XCTAssertFalse(s.isMCPOriginated)
    }
    func testRequiredFieldsMissingOrNullStillThrow() throws {
        let values=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(minimal.utf8)) as? [String:Any])
        for key in ["id","name","savedAt","autoEditEnabled"] {
            var absent=values;absent.removeValue(forKey:key)
            XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:absent)))
            var null=values;null[key]=NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self,from:JSONSerialization.data(withJSONObject:null)))
        }
    }
    func testMalformedUUIDAndOptionalFieldTypesStillThrow() {
        XCTAssertThrowsError(try decode(minimal.replacingOccurrences(of:id.uuidString,with:"invalid")))
        for fragment in ["\"workspaceID\":\"invalid\"","\"serializationVersion\":\"4\"","\"isMCPOriginated\":1","\"codexContextWindow\":\"100\"","\"items\":{}","\"providerTokenUsageByTurn\":{}"] {
            XCTAssertThrowsError(try decode(String(minimal.dropLast())+","+fragment+"}"))
        }
    }
    func testRawCodexCountsAndItemCountRemainUninterpretedByEnvelope() throws {
        let s=try decode(String(minimal.dropLast())+",\"itemCount\":-7,\"codexLastTotalTokens\":9223372036854775807}")
        XCTAssertEqual(s.itemCount,-7);XCTAssertEqual(s.codexLastTotalTokens,Int.max)
    }
    func testNilOptionalFieldsAreOmittedAndComputedStubStateIsNotEncoded() throws {
        let s=AgentSession(id:id,savedAt:date,itemCount:0)
        let values=try object(s)
        XCTAssertNil(values["transcript"]);XCTAssertNil(values["fileURL"]);XCTAssertNil(values["providerSessionID"])
        XCTAssertNil(values["isListStub"]);XCTAssertEqual(values["items"] as? [String],[])
        XCTAssertEqual(values["providerTokenUsageByTurn"] as? [String],[])
    }
    func testDateAndURLStrategiesRemainEncoderDecoderOwned() throws {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
        let data=try encoder.encode(full())
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let s=try decoder.decode(AgentSession.self,from:data)
        XCTAssertEqual(s.savedAt,date);XCTAssertEqual(s.pendingHandoffCreatedAt,date)
        XCTAssertEqual(s.fileURL,full().fileURL)
    }
    func testProviderResumeMetadataKeepsExactKeysAndLegacyOptionals() throws {
        let metadata=GeminiACPResumeMetadata(runtimeSessionID:"r",loadSessionID:"l",loadSessionIDVerifiedAt:date)
        let data=try JSONEncoder().encode(metadata)
        let keys=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(Set(keys.keys),Set(["runtimeSessionID","loadSessionID","loadSessionIDVerifiedAt"]))
        XCTAssertEqual(try JSONDecoder().decode(GeminiACPResumeMetadata.self,from:data),metadata)
        XCTAssertEqual(try JSONDecoder().decode(GeminiACPResumeMetadata.self,from:Data("{}".utf8)),.init())
    }
    func testListStubPredicateDependsOnlyOnPayloadPresenceAndCountHint() {
        XCTAssertFalse(AgentSession(id:id,savedAt:date).isListStub)
        XCTAssertTrue(AgentSession(id:id,savedAt:date,itemCount:0).isListStub)
        XCTAssertFalse(AgentSession(id:id,savedAt:date,transcript:.empty,itemCount:0).isListStub)
        XCTAssertFalse(full().isListStub)
    }
    func testValidatedNamePreservesExistingWhitespaceCollapseAndFallback() {
        XCTAssertEqual(AgentSession.validatedName(" \t\n "),"Agent Session")
        XCTAssertEqual(AgentSession.validatedName("  one\n\t two  "),"one two")
        XCTAssertEqual(AgentSession.validatedName("模型 🙂"),"模型 🙂")
    }
    func testLargeUsageArrayStreamsThroughRealEnvelopeDecoder() throws {
        let rows=Array(repeating:AgentTokenUsagePersist(promptTokens:1,completionTokens:1,timestamp:date),count:4000)
        let session=AgentSession(id:id,savedAt:date,providerTokenUsageByTurn:rows)
        let data=try JSONEncoder().encode(session)
        let probe=AgentUsageDecodeProbe(),decoder=JSONDecoder();decoder.userInfo[AgentUsageDecodeProbe.userInfoKey]=probe
        let decoded=try decoder.decode(AgentSession.self,from:data)
        XCTAssertEqual(decoded.providerTokenUsageByTurn.count,512)
        XCTAssertEqual(probe.rowsObserved,4000);XCTAssertLessThanOrEqual(probe.peakBufferedRowCount,1024)
        XCTAssertEqual(decoded.providerTokenUsageByTurn.first?.summarizedTurnCount,3489)
    }
    func testMalformedUsageSummaryCannotBecomeDetailedSessionTurn() throws {
        let json=String(minimal.dropLast())+",\"providerTokenUsageByTurn\":[{\"promptTokens\":900000,\"completionTokens\":1,\"timestamp\":0,\"summarizedTurnCount\":0}]}"
        XCTAssertTrue(try decode(json).providerTokenUsageByTurn.isEmpty)
    }
    func testIndependentSessionIDsAndWorkspaceNamespacesRemainSeparate() throws {
        var a=full(),b=full();b.workspaceID=UUID();b.composeTabID=UUID();b.providerSessionID="other"
        a.pendingHandoffPayload="first"
        let copy=try JSONDecoder().decode(AgentSession.self,from:JSONEncoder().encode(b))
        XCTAssertNotEqual(copy.workspaceID,a.workspaceID);XCTAssertNotEqual(copy.composeTabID,a.composeTabID)
        XCTAssertEqual(copy.providerSessionID,"other");XCTAssertEqual(a.providerSessionID,"raw/provider/session")
        XCTAssertEqual(a.pendingHandoffPayload,"first")
    }
}
