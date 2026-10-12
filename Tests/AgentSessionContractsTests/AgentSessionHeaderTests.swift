import XCTest
import Foundation
import AgentSessionContracts

final class AgentSessionHeaderTests:XCTestCase {
    private var minimal:String { "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"header\",\"savedAt\":0,\"autoEditEnabled\":false}" }
    private func header(_ json:String) throws -> AgentSessionHeader { try JSONDecoder().decode(AgentSessionHeader.self,from:Data(json.utf8)) }
    func testMinimalHeaderKeepsOptionalVersionAndFlagAbsence() throws {
        let h=try header(minimal)
        XCTAssertNil(h.serializationVersion);XCTAssertNil(h.itemCount);XCTAssertNil(h.isMCPOriginated)
        XCTAssertNil(h.pendingHandoffDefersProviderLockUntilSend);XCTAssertFalse(h.autoEditEnabled)
        XCTAssertEqual(h.savedAt,Date(timeIntervalSinceReferenceDate:0))
    }
    func testHeaderIgnoresMalformedHeavyPayloadWhileFullEnvelopeRejectsIt() throws {
        let json=String(minimal.dropLast())+",\"items\":{},\"transcript\":\"invalid\",\"providerTokenUsageByTurn\":42}"
        XCTAssertEqual(try header(json).name,"header")
        XCTAssertThrowsError(try JSONDecoder().decode(AgentSession.self,from:Data(json.utf8)))
    }
    func testHeaderRetainsFutureVersionAndOpaqueProviderMetadata() throws {
        let json=String(minimal.dropLast())+",\"serializationVersion\":99,\"agentKind\":\"future\",\"agentModel\":\"model/raw\",\"providerSessionID\":\"resume/raw\",\"codexMcpSessionKey\":\"mcp/raw\",\"pendingHandoffPayload\":\"handoff\",\"pendingHandoffDefersProviderLockUntilSend\":true}"
        let h=try header(json)
        XCTAssertEqual(h.serializationVersion,99);XCTAssertEqual(h.agentKind,"future")
        XCTAssertEqual(h.agentModel,"model/raw");XCTAssertEqual(h.providerSessionID,"resume/raw")
        XCTAssertEqual(h.codexMcpSessionKey,"mcp/raw");XCTAssertEqual(h.pendingHandoffPayload,"handoff")
        XCTAssertEqual(h.pendingHandoffDefersProviderLockUntilSend,true)
    }
    func testHeaderProjectionCountsAndProviderResumeMetadataKeepExactValues() throws {
        let json=String(minimal.dropLast())+",\"itemCount\":10,\"transcriptProjectionCounts\":{\"canonicalVisibleRowCount\":9,\"defaultPresentedRowCount\":4},\"geminiACPResumeMetadata\":{\"runtimeSessionID\":\"r\",\"loadSessionID\":\"l\",\"loadSessionIDVerifiedAt\":0}}"
        let h=try header(json)
        XCTAssertEqual(h.itemCount,10);XCTAssertEqual(h.transcriptProjectionCounts?.canonicalVisibleRowCount,9)
        XCTAssertEqual(h.transcriptProjectionCounts?.defaultPresentedRowCount,4)
        XCTAssertEqual(h.geminiACPResumeMetadata?.runtimeSessionID,"r");XCTAssertEqual(h.geminiACPResumeMetadata?.loadSessionID,"l")
        XCTAssertEqual(h.geminiACPResumeMetadata?.loadSessionIDVerifiedAt,Date(timeIntervalSinceReferenceDate:0))
    }
    func testHeaderRequiredFieldsAndMalformedOptionalMetadataStillThrow() {
        for json in ["{}",minimal.replacingOccurrences(of:"false",with:"null"),String(minimal.dropLast())+",\"itemCount\":\"10\"}",String(minimal.dropLast())+",\"isMCPOriginated\":1}"] {
            XCTAssertThrowsError(try header(json))
        }
    }
    func testHeaderNullMetadataIsNotPromotedToDefaults() throws {
        let h=try header(String(minimal.dropLast())+",\"serializationVersion\":null,\"isMCPOriginated\":null,\"pendingHandoffDefersProviderLockUntilSend\":null}")
        XCTAssertNil(h.serializationVersion);XCTAssertNil(h.isMCPOriginated);XCTAssertNil(h.pendingHandoffDefersProviderLockUntilSend)
    }
}
