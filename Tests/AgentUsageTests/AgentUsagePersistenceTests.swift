import XCTest
import Foundation
import AgentUsage
import AgentRuntimeKit

private struct UsageEnvelope: Decodable {
    let rows: [AgentTokenUsagePersist]
    enum CodingKeys: String, CodingKey { case rows }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try AgentTokenUsagePersist.decodeBoundedRetained(from: container, forKey: .rows,
            probe: decoder.userInfo[AgentUsageDecodeProbe.userInfoKey] as? AgentUsageDecodeProbe)
    }
}
final class AgentUsagePersistenceTests: XCTestCase {
    private func row(prompt: Int = 1, completion: Int = 1, context: Int? = nil,
                     estimate: Int = 0, count: Int? = nil, openCode: Int? = nil,
                     lastGemini: Int? = nil, cumulativeGemini: Int? = nil) -> AgentTokenUsagePersist {
        .init(promptTokens: prompt, completionTokens: completion, contextUsedTokens: context,
              estimatedUserInputTokens: estimate, timestamp: Date(timeIntervalSince1970: 123),
              summarizedTurnCount: count, summarizedOpenCodeLatestReading: openCode,
              summarizedGeminiLastTurnTotal: lastGemini, summarizedGeminiCumulativeTotal: cumulativeGemini)
    }
    private func decode(_ rows: String, probe: AgentUsageDecodeProbe? = nil) throws -> [AgentTokenUsagePersist] {
        let decoder = JSONDecoder(); decoder.userInfo[AgentUsageDecodeProbe.userInfoKey] = probe
        return try decoder.decode(UsageEnvelope.self, from: Data("{\"rows\":[\(rows)]}".utf8)).rows
    }
    private func encoded(_ row: AgentTokenUsagePersist) throws -> String { String(decoding: try JSONEncoder().encode(row), as: UTF8.self) }
    func testLegacyRowJSONDefaultsMissingEstimatesAndPreservesDates() throws {
        let decoded = try JSONDecoder().decode(AgentTokenUsagePersist.self,
            from: Data("{\"promptTokens\":7,\"completionTokens\":3,\"timestamp\":0,\"unknown\":true}".utf8))
        XCTAssertEqual(decoded.promptTokens, 7); XCTAssertEqual(decoded.completionTokens, 3)
        XCTAssertEqual(decoded.estimatedInputTokens, 0)
        XCTAssertEqual(decoded.timestamp, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertFalse(decoded.isCumulativeSummary); XCTAssertFalse(decoded.hasInvalidSummaryMetadata)
    }
    func testCurrentRowEncodesExactLegacyFieldSetAndOmitsDecodeFlags() throws {
        let value = row(context: 100, count: 4, openCode: 200, lastGemini: 20, cumulativeGemini: 80)
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["promptTokens","completionTokens","contextUsedTokens","estimatedUserInputTokens","estimatedToolInputTokens","estimatedToolOutputTokens","timestamp","summarizedTurnCount","summarizedOpenCodeLatestReading","summarizedGeminiLastTurnTotal","summarizedGeminiCumulativeTotal"]))
        XCTAssertEqual(try JSONDecoder().decode(AgentTokenUsagePersist.self, from: data), value)
    }
    func testDetailedRowOmitsAbsentSummaryAndContextKeys() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row())) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["promptTokens","completionTokens","estimatedUserInputTokens","estimatedToolInputTokens","estimatedToolOutputTokens","timestamp"]))
    }
    func testWrongTypesAndMissingRequiredFieldsStillThrow() throws {
        for json in ["{}", "{\"promptTokens\":\"7\",\"completionTokens\":3,\"timestamp\":0}", "{\"promptTokens\":7,\"completionTokens\":3,\"timestamp\":null}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AgentTokenUsagePersist.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try decode("null"))
    }
    func testMissingAndNullCollectionsDecodeEmptyButWrongCollectionTypeThrows() throws {
        for json in ["{}", "{\"rows\":null}"] {
            XCTAssertEqual(try JSONDecoder().decode(UsageEnvelope.self, from: Data(json.utf8)).rows, [])
        }
        XCTAssertThrowsError(try JSONDecoder().decode(UsageEnvelope.self, from: Data("{\"rows\":5}".utf8)))
    }
    func testHostileIndividualCountsDropToZeroAndDerivedDomainIsDistinct() throws {
        let value = row(prompt: Int.max, completion: -1, context: Int.max, estimate: Int.max)
        XCTAssertEqual(value.providerTotalTokens, 0); XCTAssertEqual(value.estimatedInputTokens, 0); XCTAssertNil(value.contextUsedTokens)
        XCTAssertEqual(AgentTokenUsagePersist.boundedTokenCount(1_000_000_000_000), 1_000_000_000_000)
        XCTAssertEqual(AgentTokenUsagePersist.boundedTokenCount(1_000_000_000_001), 0)
        XCTAssertEqual(AgentTokenUsagePersist.boundedDerivedTotalCount(3_000_000_000_000), 3_000_000_000_000)
        XCTAssertNil(AgentTokenUsagePersist.boundedDerivedTotalCount(3_000_000_000_001))
        let hostile = try JSONDecoder().decode(AgentTokenUsagePersist.self, from: Data("{\"promptTokens\":9223372036854775807,\"completionTokens\":-1,\"timestamp\":0}".utf8))
        XCTAssertEqual(hostile.providerTotalTokens, 0)
    }
    func testCumulativeReductionCannotOverflowAndNeverCountsNegativeValues() {
        XCTAssertEqual(AgentTokenUsagePersist.clampedSum([Int.max, Int.max]), AgentTokenUsagePersist.maxPersistedTokenCount)
        XCTAssertEqual(AgentTokenUsagePersist.clampedSum([-5, 7, 3]), 10)
    }
    func testSummaryPreservesEachProvidersReadingRatherThanUsingAggregateAsTurn() {
        let rows = [row(prompt: 5, completion: 2, context: 90), row(prompt: 0, completion: 0, context: 100, estimate: 4), row(prompt: 0, completion: 0)]
        let retained = AgentTokenUsagePersist.retained(rows, limit: 2)
        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(retained[0].summarizedTurnCount, 2)
        XCTAssertEqual(retained[0].contextUsedTokens, 100)
        XCTAssertEqual(retained[0].summarizedOpenCodeLatestReading, 100)
        XCTAssertEqual(retained[0].summarizedGeminiLastTurnTotal, 4)
        XCTAssertEqual(retained[0].summarizedGeminiCumulativeTotal, 11)
        XCTAssertEqual(AgentUsageRestoration.openCode(retained, modelContextWindow: nil)?.lastTotalTokens, 100)
        XCTAssertEqual(AgentUsageRestoration.gemini(retained, modelContextWindow: nil)?.lastTotalTokens, 4)
        XCTAssertEqual(AgentUsageRestoration.gemini(retained, modelContextWindow: nil)?.totalTotalTokens, 11)
    }
    func testRepeatedRetentionPreservesLatestReadingsAndSingleLeadingSummary() {
        let rows = (0..<900).map { row(context: $0 + 1) }
        let first = AgentTokenUsagePersist.retained(rows)
        let twice = AgentTokenUsagePersist.retained(first + [row(context: 1000)])
        XCTAssertEqual(twice.count, 512)
        XCTAssertEqual(twice.filter(\.isCumulativeSummary).count, 1)
        XCTAssertEqual(twice.first?.summarizedTurnCount, 390)
        XCTAssertEqual(AgentUsageRestoration.openCode(twice, modelContextWindow: nil)?.lastTotalTokens, 1000)
        XCTAssertEqual(AgentUsageRestoration.gemini(twice, modelContextWindow: nil)?.totalTotalTokens, 1802)
    }
    func testDerivedProviderReadingAboveSingleFieldDomainSurvivesSummary() {
        let big = row(prompt: 1_000_000_000_000, completion: 900_000_000_000)
        let retained = AgentTokenUsagePersist.retained([big] + Array(repeating: row(prompt: 0, completion: 0), count: 512))
        XCTAssertEqual(retained.first?.summarizedOpenCodeLatestReading, 1_900_000_000_000)
        XCTAssertEqual(AgentUsageRestoration.openCode(retained, modelContextWindow: nil)?.lastTotalTokens, 1_900_000_000_000)
    }
    func testStreamingDecodeMatchesRetentionForLargeValidCollectionAndBoundsBuffer() throws {
        let rows = (0..<5000).map { row(context: $0 + 1) }
        let probe = AgentUsageDecodeProbe()
        let data = try JSONEncoder().encode(["rows":rows])
        let decoder = JSONDecoder(); decoder.userInfo[AgentUsageDecodeProbe.userInfoKey] = probe
        let decoded = try decoder.decode(UsageEnvelope.self, from: data).rows
        XCTAssertEqual(decoded, AgentTokenUsagePersist.retained(rows))
        XCTAssertEqual(probe.rowsObserved, 5000)
        XCTAssertGreaterThan(probe.peakBufferedRowCount, 0)
        XCTAssertLessThanOrEqual(probe.peakBufferedRowCount, 1024)
        XCTAssertFalse(probe.malformedSummaryStructure)
    }
    func testLeadingSummarySeedsStreamingAccumulatorAndPreservesSuffix() throws {
        let values = [row(count: 20, openCode: 800, lastGemini: 3, cumulativeGemini: 60), row(context: 100)]
        let text = try values.map(encoded).joined(separator: ",")
        let decoded = try decode(text)
        XCTAssertEqual(decoded, values)
        XCTAssertEqual(AgentUsageRestoration.openCode(decoded, modelContextWindow: nil)?.lastTotalTokens, 100)
        XCTAssertEqual(AgentUsageRestoration.gemini(decoded, modelContextWindow: nil)?.totalTotalTokens, 62)
    }
    func testMisplacedAndDuplicateSummariesDistrustAllAggregates() throws {
        let summary = row(count: 20, openCode: 800)
        for values in [[row(context: 10),summary,row(context: 20)], [summary,summary,row(context: 20)]] {
            let probe = AgentUsageDecodeProbe()
            let result = try decode(values.map(encoded).joined(separator: ","), probe: probe)
            XCTAssertFalse(result.contains(where: \.isCumulativeSummary))
            XCTAssertTrue(probe.malformedSummaryStructure)
            XCTAssertEqual(result, AgentTokenUsagePersist.retained(values))
        }
    }
    func testPresentInvalidMarkersCannotPromoteAggregateToDetailedTurn() throws {
        for marker in ["0", "-1", "1000000000001"] {
            let aggregate = "{\"promptTokens\":700000,\"completionTokens\":200000,\"timestamp\":0,\"summarizedTurnCount\":\(marker)}"
            let probe = AgentUsageDecodeProbe()
            let detail = row(context: 30)
            let result = try decode(aggregate + "," + encoded(detail), probe: probe)
            XCTAssertEqual(result, [detail]); XCTAssertTrue(probe.malformedSummaryStructure)
        }
    }
    func testInvalidCompanionsDropSummaryButKeepOrphanDetailedRow() throws {
        for value in ["-7", "3000000000001"] {
            let invalid = "{\"promptTokens\":7,\"completionTokens\":3,\"timestamp\":0,\"summarizedOpenCodeLatestReading\":\(value)"
            let detailed = try decode(invalid + "}")
            XCTAssertEqual(detailed.first?.providerTotalTokens, 10)
            XCTAssertFalse(detailed[0].hasSummaryCompanionFields)
            XCTAssertEqual(try decode(invalid + ",\"summarizedTurnCount\":5}"), [])
        }
    }
    func testOrphanNoiseDistrustsLegitimateLeadingSummaryAndKeepsRealTurn() throws {
        let summary = row(count: 20, openCode: 800)
        let orphan = row(context: 40, lastGemini: 123)
        let result = try decode(encoded(summary) + "," + encoded(orphan))
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].hasSummaryCompanionFields)
        XCTAssertEqual(result[0].contextUsedTokens, 40)
    }
    func testMalformedMetadataFlagsNeverPersistAndNullSummaryKeepsLegacySemantics() throws {
        let raw = "{\"promptTokens\":7,\"completionTokens\":3,\"timestamp\":0,\"summarizedTurnCount\":0}"
        let value = try JSONDecoder().decode(AgentTokenUsagePersist.self, from: Data(raw.utf8))
        XCTAssertTrue(value.hasInvalidSummaryMarker)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNil(object["hasInvalidSummaryMarker"]); XCTAssertNil(object["summarizedTurnCount"])
        let null = raw.replacingOccurrences(of: "\"summarizedTurnCount\":0", with: "\"summarizedTurnCount\":null")
        XCTAssertFalse(try JSONDecoder().decode(AgentTokenUsagePersist.self, from: Data(null.utf8)).hasInvalidSummaryMarker)
    }
    func testLowRetentionLimitPreservesExistingSummaryPlusOneDetailSemantics() {
        let rows = [row(),row(),row()]
        XCTAssertEqual(AgentTokenUsagePersist.retained(rows, limit: 1).count, 2)
        XCTAssertEqual(AgentTokenUsagePersist.retained(rows, limit: 0), AgentTokenUsagePersist.retained(rows, limit: 1))
    }
    func testUnknownFieldsDoNotChangeStreamingUsage() throws {
        XCTAssertEqual(try decode("{\"promptTokens\":7,\"completionTokens\":3,\"timestamp\":0,\"futureField\":{\"version\":99}}"), [.init(promptTokens: 7, completionTokens: 3, timestamp: Date(timeIntervalSinceReferenceDate: 0))])
    }
    func testConcurrentIndependentDecodersCanShareInstrumentation() async throws {
        let probe = AgentUsageDecodeProbe()
        let data = try JSONEncoder().encode(["rows":Array(repeating: row(), count: 1200)])
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let decoder = JSONDecoder(); decoder.userInfo[AgentUsageDecodeProbe.userInfoKey] = probe
                    return try decoder.decode(UsageEnvelope.self, from: data).rows.count
                }
            }
            for try await count in group { XCTAssertEqual(count, 512) }
        }
        XCTAssertEqual(probe.rowsObserved, 24_000)
        XCTAssertLessThanOrEqual(probe.peakBufferedRowCount, 1024)
        XCTAssertFalse(probe.malformedSummaryStructure)
    }
}
