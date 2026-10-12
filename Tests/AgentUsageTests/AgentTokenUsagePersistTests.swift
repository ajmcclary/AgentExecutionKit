import XCTest
import AgentUsage

final class AgentTokenUsagePersistTests: XCTestCase {
	func testTotalTokensPrefersProviderTotalsWhenAvailable() {
		let usage = AgentTokenUsagePersist(
			promptTokens: 120,
			completionTokens: 30,
			estimatedUserInputTokens: 40,
			estimatedToolInputTokens: 10,
			estimatedToolOutputTokens: 5
		)

		XCTAssertEqual(usage.providerTotalTokens, 150)
		XCTAssertEqual(usage.estimatedInputTokens, 55)
		XCTAssertEqual(usage.totalTokens, 150)
	}

	func testTotalTokensFallsBackToEstimatesWhenProviderTotalsMissing() {
		let usage = AgentTokenUsagePersist(
			promptTokens: 0,
			completionTokens: 0,
			estimatedUserInputTokens: 40,
			estimatedToolInputTokens: 10,
			estimatedToolOutputTokens: 5
		)

		XCTAssertEqual(usage.providerTotalTokens, 0)
		XCTAssertEqual(usage.estimatedInputTokens, 55)
		XCTAssertEqual(usage.totalTokens, 55)
	}

	func testTotalTokensPrefersContextUsedWhenAvailable() {
		let usage = AgentTokenUsagePersist(
			promptTokens: 120,
			completionTokens: 30,
			contextUsedTokens: 180,
			estimatedUserInputTokens: 40,
			estimatedToolInputTokens: 10,
			estimatedToolOutputTokens: 5
		)

		XCTAssertEqual(usage.providerTotalTokens, 150)
		XCTAssertEqual(usage.totalTokens, 180)
	}
}
