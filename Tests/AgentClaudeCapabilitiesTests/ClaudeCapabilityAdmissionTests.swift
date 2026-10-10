import XCTest
import AgentClaudeCapabilities
import ClaudeRuntimeKit

final class ClaudeCapabilityAdmissionTests: XCTestCase {
    private enum Effort: String, Sendable { case high, low }
    private func project(_ decision: ClaudeAdmissionDecision) -> ClaudeSessionCapabilityProjection<Effort> {
        .project(evaluation: .init(assessment: .init(classification: .behaviorUnavailable,
                    interrupt: .uncertified, offered: .none, limitations: []), decision: decision),
                 sessionModel: "opus", sessionEffortLevel: .high,
                 staticModelCatalog: ["opus", "sonnet"], staticEffortCatalog: [.low, .high],
                 modelsValue: ["opus", "unknown"], fastModeStateValue: ["effort": "high"],
                 parseEffort: { Effort(rawValue: $0) })
    }

    func testCertifiedCatalogBoundsRuntimeAndHostWithoutFallbackForEmptyEffort() {
        let p = project(.admitFull(.init(models: ["opus", "alien"], effortLevels: [],
                                       structuredOutput: true, resume: false, permissionModeRoundTrip: true)))
        XCTAssertEqual(p.dynamic.effectiveModels, ["opus"])
        XCTAssertEqual(p.dynamic.effectiveEffortLevels, [])
        XCTAssertFalse(p.offersResume); XCTAssertTrue(p.offersStructuredOutput)
        XCTAssertFalse(p.interruptSafetyPreconditionSatisfied)
        XCTAssertEqual(p.sessionModel, "opus"); XCTAssertEqual(p.sessionEffortLevel, .high)
    }

    func testLimitedAndRejectedDecisionsCannotWidenCapabilities() {
        let limited = project(.admitLimited(reason: .limitedClassification,
                            offered: .init(models: ["sonnet"], effortLevels: ["low"],
                                           structuredOutput: false, resume: false, permissionModeRoundTrip: false),
                            limitations: ["limited"]))
        XCTAssertEqual(limited.dynamic.effectiveModels, [])
        XCTAssertEqual(limited.dynamic.effectiveEffortLevels, [.low])
        XCTAssertFalse(limited.offersResume); XCTAssertFalse(limited.offersStructuredOutput)
        let rejected = project(.reject(.externalOnly))
        XCTAssertEqual(rejected.dynamic.effectiveModels, [])
        XCTAssertEqual(rejected.dynamic.effectiveEffortLevels, [])
        XCTAssertEqual(rejected.offeredModels, [])
    }

    func testStageZeroAndOneObserveWhileTwoAndThreeRefuse() {
        let p = project(.admitUnrestricted)
        for stage in [ClaudeAdmissionEnforcementStage.observeOnly, .enforceKnownBad] {
            XCTAssertEqual(p.admits(model: "alien", effortLevel: .low, stage: stage),
                           .allowedObservedOnly(reason: .modelNotOffered(requested: "alien")))
        }
        for stage in [ClaudeAdmissionEnforcementStage.enforceLimited, .enforceAll] {
            XCTAssertEqual(p.admits(model: "alien", effortLevel: .low, stage: stage),
                           .refused(.modelNotOffered(requested: "alien")))
            XCTAssertEqual(p.admits(model: " Opus:high ", effortLevel: .high, stage: stage), .allowed)
            XCTAssertEqual(p.admits(model: nil, effortLevel: .low, stage: stage),
                           .refused(.effortNotOffered(requested: "low")))
        }
    }
}
