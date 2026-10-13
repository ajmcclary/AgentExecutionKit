import XCTest
import Foundation
import AgentRuntimeKit
import AgentTranscriptAssembly
import AgentTranscriptExport

final class AgentTranscriptExportTests: XCTestCase {
    let t1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let t2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    func row(_ kind: AgentChatItemKind, _ text: String = "", name: String? = nil, args: String? = nil, result: String? = nil) -> AgentChatItem {
        .init(timestamp: Date(timeIntervalSince1970: 100), kind: kind, text: text, toolName: name, toolArgsJSON: args, toolResultJSON: result, sequenceIndex: 90)
    }
    func entry(_ item: AgentChatItem, turn: UUID? = nil, boundary: Bool? = nil) -> AgentTranscriptExportEntry {
        .init(migratedItem: item, sourceRowID: item.id, xmlItems: [item], turnID: turn ?? t1, isToolBoundary: boundary ?? (item.kind == .toolCall))
    }
    func service() -> AgentTranscriptExportService {
        .init(suppressRow: { $0.toolName == "hidden" }, visibleToolName: { $0 == "unknown" ? nil : $0?.lowercased() })
    }
    func xml(_ entries: [AgentTranscriptExportEntry], budget: Int = 200, args: Int = 2_000) -> String {
        service().forkXML(from: entries, maxTranscriptItems: budget, maxToolArgsCharacters: args)
    }
    func testEmptyExport() { XCTAssertEqual(xml([]), "<transcript>\n</transcript>") }
    func testRawXMLLikeTextAndTrimmedAssistantArePreserved() {
        XCTAssertEqual(xml([entry(row(.user," <request>& ")),entry(row(.assistant,"  answer<> \n")),entry(row(.error," fault \n"))]), "<transcript>\n<user> <request>& </user>\n<assistant>answer<></assistant>\n<error>fault</error>\n</transcript>")
    }
    func testNonDisplayableAndNonExportableRows() {
        XCTAssertEqual(xml([entry(row(.assistant," \n")), entry(row(.assistantInline,"\u{200B}")),entry(row(.thinking,"secret")),entry(row(.toolResult,"result")),entry(row(.system," ")),entry(row(.error,"\n"))]),"<transcript>\n</transcript>")
    }
    func testToolVisibilityNormalizationAndArgumentTruncation() {
        XCTAssertEqual(xml([entry(row(.toolCall,name:"READ",args:"12345")),entry(row(.toolCall,name:"hidden")),entry(row(.toolCall,name:"unknown")),entry(row(.toolCall)),entry(row(.toolCall,name:"EMPTY"))],args:3),"<transcript>\n<tool_call name=\"read\">123…</tool_call>\n<tool_call name=\"empty\"/>\n</transcript>")
    }
    func testExactArgumentLimitKeepsAllCharacters() {
        XCTAssertTrue(xml([entry(row(.toolCall,name:"read",args:"👨‍👩‍👧‍👦é"))],args:2).contains("👨‍👩‍👧‍👦é</tool_call>"))
    }
    func testToolThenSupplementalThenContextDropPriority() {
        let entries=[entry(row(.user,"prompt")),entry(row(.assistant,"intent")),entry(row(.toolCall,name:"read")),entry(row(.system,"context")),entry(row(.assistant,"conclusion"))]
        let four=xml(entries,budget:4);XCTAssertFalse(four.contains("<tool_call"));XCTAssertTrue(four.contains("intent"));XCTAssertTrue(four.contains("1 item omitted"))
        let three=xml(entries,budget:3);XCTAssertFalse(three.contains("intent"));XCTAssertTrue(three.contains("context"))
        let two=xml(entries,budget:2);XCTAssertFalse(two.contains("context"));XCTAssertTrue(two.contains("prompt"));XCTAssertTrue(two.contains("conclusion"));XCTAssertTrue(two.contains("3 items omitted"))
    }
    func testOldestItemWithinDropTier() {
        let result=xml([entry(row(.toolCall,name:"old")),entry(row(.toolCall,name:"new")),entry(row(.assistant,"done"))],budget:2)
        XCTAssertFalse(result.contains("old"));XCTAssertTrue(result.contains("new"))
    }
    func testWholeTurnsDropTogether() {
        let result=xml([entry(row(.user,"old prompt")),entry(row(.assistant,"old answer")),entry(row(.user,"new prompt"),turn:t2),entry(row(.assistant,"new answer"),turn:t2)],budget:3)
        XCTAssertFalse(result.contains("old"));XCTAssertTrue(result.contains("new prompt"));XCTAssertTrue(result.contains("new answer"));XCTAssertTrue(result.contains("2 items omitted"))
    }
    func testConclusionIdentityUsesLastDisplayableAssistantAcrossSameTurn() {
        let result=xml([entry(row(.assistant,"first")),entry(row(.assistantInline,"last")),entry(row(.assistant,"\n"))],budget:1)
        XCTAssertFalse(result.contains("first"));XCTAssertTrue(result.contains("last"))
    }
    func testMergedSystemRowsConsumeOneBudgetItemAcrossTurns() {
        XCTAssertEqual(xml([entry(row(.system,"a")),entry(row(.system,"b"),turn:t2)],budget:1),"<transcript>\n<system>a\nb</system>\n</transcript>")
    }
    func testDroppingSeparatorRecountsMergedSystemRows() {
        let result=xml([entry(row(.system,"a")),entry(row(.toolCall,name:"read")),entry(row(.system,"b")),entry(row(.assistant,"done"))],budget:2)
        XCTAssertTrue(result.contains("<system>a\nb</system>"));XCTAssertTrue(result.contains("1 item omitted"))
    }
    func testUngroupedUserIsPreservedEvenWhenBudgetCannotFitIt() {
        let item=row(.user,"unowned");let e=AgentTranscriptExportEntry(migratedItem:item,sourceRowID:item.id,xmlItems:[item],turnID:nil,isToolBoundary:false)
        XCTAssertEqual(xml([e],budget:0),"<transcript>\n<user>unowned</user>\n</transcript>")
    }
    func testZeroBudgetDropsOwnedEssentialTurn() {
        XCTAssertEqual(xml([entry(row(.user,"prompt")),entry(row(.assistant,"done"))],budget:0),"<transcript>\n<note>2 items omitted to fit 0 item budget.</note>\n</transcript>")
    }
    func testDiagnosticAndSummaryOnlyFilteringPreservesHistoricalSubstringRules() {
        let input=[entry(row(.error," \n[ede_diagnostic] internal")),entry(row(.toolResult,result:"{\"summary_only\":true}")),entry(row(.toolResult,"{\"summary_only\": true}")),entry(row(.toolResult,result:"{\"summary_only\" : true}")),entry(row(.error,"ordinary"))]
        XCTAssertEqual(service().filteredEntries(input,preserveIntermediateAssistantNarration:true).map{$0.xmlItems[0].text},["","ordinary"])
    }
    func testFilterInspectsFirstXMLItemOnly() {
        let e=AgentTranscriptExportEntry(migratedItem:nil,sourceRowID:nil,xmlItems:[row(.system,"valid"),row(.error,"[ede_diagnostic] nested")],turnID:t1,isToolBoundary:false)
        XCTAssertEqual(service().filteredEntries([e]).count,1)
    }
    func testEmptyPreviewStillMigratesCompletedResult() {
        var item=row(.toolResult,"failed",name:"read",result:"{\"isError\":true}");item.toolIsError=true;item.isStreaming=true
        let e=AgentTranscriptExportEntry(migratedItem:item,sourceRowID:item.id,xmlItems:[],turnID:t1,isToolBoundary:true)
        let migrated=AgentTranscriptExportService.migratedItems(from:service().filteredEntries([e]));XCTAssertEqual(migrated.count,1);XCTAssertEqual(migrated[0].id,item.id);XCTAssertEqual(migrated[0].toolIsError,true);XCTAssertEqual(migrated[0].toolResultJSON,item.toolResultJSON);XCTAssertFalse(migrated[0].isStreaming);XCTAssertEqual(xml([e]),"<transcript>\n</transcript>")
    }
    func testMigratedRowsAreRenumberedWithoutChangingSourceIdentityOrTime() {
        var a=row(.user,"a");a.isStreaming=true;let b=row(.assistant,"b")
        let preview=AgentTranscriptExportEntry(migratedItem:nil,sourceRowID:nil,xmlItems:[row(.system,"preview")],turnID:t1,isToolBoundary:true)
        let result=AgentTranscriptExportService.migratedItems(from:[entry(a),preview,entry(b)])
        XCTAssertEqual(result.map(\.sequenceIndex),[0,1]);XCTAssertEqual(result.map(\.id),[a.id,b.id]);XCTAssertEqual(result.map(\.timestamp),[a.timestamp,b.timestamp]);XCTAssertFalse(result[0].isStreaming);XCTAssertTrue(a.isStreaming)
    }
    func narration() -> [AgentTranscriptExportEntry] {
        [entry(row(.assistant,"intent")),entry(row(.toolCall,name:"read")),entry(row(.assistant,"first intermediate")),entry(row(.toolCall,name:"edit")),entry(row(.assistantInline,String(repeating:"x",count:250))),entry(row(.toolCall,name:"verify")),entry(row(.assistant,"conclusion")),entry(row(.assistant," \n"))]
    }
    func testIntermediateNarrationDropsEarlierAndTruncatesLastInBothPayloads() {
        let result=service().filteredEntries(narration());let assistant=result.filter{$0.xmlItems.first?.kind == .assistant || $0.xmlItems.first?.kind == .assistantInline}
        XCTAssertEqual(assistant.map{$0.xmlItems[0].text},["intent",String(repeating:"x",count:220)+"…","conclusion"," \n"])
        XCTAssertEqual(assistant[1].migratedItem?.text,assistant[1].xmlItems[0].text)
    }
    func testMonitorPreservesIntermediateNarration() {
        XCTAssertEqual(service().filteredEntries(narration(),preserveIntermediateAssistantNarration:true).count,8)
    }
    func testNarrationResetsAtContiguousTurnSegments() {
        let input=[entry(row(.toolCall,name:"read")),entry(row(.assistant,"done")),entry(row(.user,"second"),turn:t2),entry(row(.assistant,"reappeared")),entry(row(.assistant,"last"))]
        XCTAssertEqual(service().filteredEntries(input).count,input.count)
    }
    func testSummaryAndEmptyPreviewAreToolBoundaries() {
        let boundary=AgentTranscriptExportEntry(migratedItem:nil,sourceRowID:nil,xmlItems:[],turnID:t1,isToolBoundary:true)
        let result=service().filteredEntries([boundary,entry(row(.assistant,"drop")),entry(row(.system,"summary"),boundary:true),entry(row(.assistant,String(repeating:"y",count:250))),entry(row(.assistant,"done"))])
        XCTAssertFalse(result.flatMap(\.xmlItems).contains{$0.text == "drop"});XCTAssertTrue(result.flatMap(\.xmlItems).contains{$0.text == String(repeating:"y",count:220)+"…"})
    }
    func testCompactTextUsesCharacterLimitAndTrimsWhitespace() {
        XCTAssertNil(AgentTranscriptExportService.compactConclusionText(from:nil));XCTAssertNil(AgentTranscriptExportService.compactConclusionText(from:" \n"))
        XCTAssertEqual(AgentTranscriptExportService.compactConclusionText(from:" a "),"a")
        XCTAssertEqual(AgentTranscriptExportService.compactConclusionText(from:String(repeating:"é",count:221)),String(repeating:"é",count:220)+"…")
    }
    func testDiagnosticsAreExplicitlyInjected() {
        var diagnostics:[String]=[];let s=AgentTranscriptExportService(suppressRow:{_ in false},visibleToolName:{$0},diagnostics:{diagnostics.append($0)})
        _=s.forkXML(from:[entry(row(.user,"a"))]);_ = s.filteredEntries(narration());XCTAssertEqual(diagnostics.count,2)
    }
    func cutoffFixture() -> (AgentTranscript, UUID, UUID, UUID) {
        let request=row(.user,"request"),activity=row(.assistant,"answer"),summaryID=UUID()
        let span=AgentTranscriptProviderResponseSpan(startedAt:activity.timestamp,activities:[AgentTranscriptActivity(from:activity)])
        let summary=AgentTranscriptTurnSummary(middleSummaryItemID:summaryID,requestText:nil,conclusionText:"done",compactConclusionText:nil,middleSummaryText:"context",toolCount:0,notableToolNames:[],keyPaths:[],compactedActivityCount:0,hadWarning:false,hadError:false)
        let turns=[AgentTranscriptTurn(id:t1,request:.init(from:request),responseSpans:[span],summary:summary,startedAt:request.timestamp),AgentTranscriptTurn(id:t2,startedAt:request.timestamp)]
        return (.init(turns:turns),request.id,activity.id,summaryID)
    }
    func testTurnCutoffRecognizesRequestActivitySummaryAndSyntheticConclusion() {
        let (transcript,request,activity,summary)=cutoffFixture()
        for id in [request,activity,summary,AgentTranscriptIdentity.conclusionID(for:t1)] {
            XCTAssertEqual(AgentTranscriptExportService.turnsForExport(from:transcript,upToRowID:id).map(\.id),[t1])
        }
    }
    func testUnknownOrNilTurnCutoffRetainsFullTranscript() {
        let (transcript,_,_,_)=cutoffFixture()
        XCTAssertEqual(AgentTranscriptExportService.turnsForExport(from:transcript,upToRowID:UUID()),transcript.turns)
        XCTAssertEqual(AgentTranscriptExportService.turnsForExport(from:transcript,upToRowID:nil),transcript.turns)
    }
    func testSyntheticConclusionCutoffRequiresSummaryAndMissingConclusionActivity() {
        var (transcript,_,activity,_)=cutoffFixture();let synthetic=AgentTranscriptIdentity.conclusionID(for:t1)
        transcript.turns[0].conclusionActivityID=activity
        XCTAssertEqual(AgentTranscriptExportService.turnsForExport(from:transcript,upToRowID:synthetic).count,2)
        transcript.turns[0].conclusionActivityID=nil;transcript.turns[0].summary=nil
        XCTAssertEqual(AgentTranscriptExportService.turnsForExport(from:transcript,upToRowID:synthetic).count,2)
    }

}
