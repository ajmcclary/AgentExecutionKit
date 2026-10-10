import XCTest
@testable import AgentClaudeCapabilities

/// Item 10 — dynamic capability gating (plan §6).
///
///     effectiveModels = staticConservativeCatalog ∩ parse(modelsJSON)
///     effectiveModels = staticConservativeCatalog          // parse fails or absent
///
/// The load-bearing claim is the one a careless implementation gets backwards:
/// **intersection, never union.** A runtime advertising a model the app has no code
/// for must never make it selectable. `testAdvertisedButUnknownModelIsNeverOffered`
/// is the direct test; `testProjectionIsAlwaysASubsetOfTheStaticCatalog` is the
/// property that holds across every input shape at once, so a new parser branch
/// cannot introduce a union without failing something.
final class ClaudeDynamicCapabilityProjectionTests: XCTestCase {

	private let staticCatalog = ["opus", "sonnet", "haiku"]
	private let staticEfforts: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .max, .xhigh]

	private func project(
		models: Any? = nil,
		fastMode: Any? = nil,
		catalog: [String]? = nil
	) -> ClaudeDynamicCapabilities {
		ClaudeDynamicCapabilityProjector.project(
			staticModelCatalog: catalog ?? staticCatalog,
			staticEffortCatalog: staticEfforts,
			modelsValue: models,
			fastModeStateValue: fastMode, parseEffort: { ClaudeCodeEffortLevel.parse($0) })
	}

	// MARK: - Valid input

	func testValidAdvertisedModelsNarrowTheStaticCatalog() {
		let result = project(models: ["opus", "sonnet"])
		XCTAssertEqual(result.effectiveModels, ["opus", "sonnet"])
		XCTAssertEqual(result.modelsSource, .runtimeIntersected)
		XCTAssertFalse(result.effectiveModels.contains("haiku"),
					   "a model the runtime did not advertise must not be offered")
	}

	func testObjectShapedAdvertisementIsParsed() {
		let result = project(models: [["model": "opus"], ["id": "haiku"]])
		XCTAssertEqual(result.effectiveModels, ["opus", "haiku"])
		XCTAssertEqual(result.modelsSource, .runtimeIntersected)
	}

	func testWrapperObjectAndJSONStringShapesAreParsed() {
		XCTAssertEqual(project(models: ["models": ["opus"]]).effectiveModels, ["opus"])
		XCTAssertEqual(project(models: "[\"sonnet\"]").effectiveModels, ["sonnet"])
	}

	// MARK: - Absent / malformed / unknown all fall back to the STATIC catalog

	func testAbsentModelsFallBackToTheStaticCatalog() {
		let result = project(models: nil)
		XCTAssertEqual(result.effectiveModels, staticCatalog)
		XCTAssertEqual(result.modelsSource, .staticFallback)
		XCTAssertTrue(result.diagnostics.contains(.modelsAbsent))
	}

	func testMalformedModelsFallBackToTheStaticCatalogAndAreNeverFatal() {
		for malformed: Any in [42, "not json at all", [Int](), [String: Any](), "{"] {
			let result = project(models: malformed)
			XCTAssertEqual(result.effectiveModels, staticCatalog,
						   "malformed input \(malformed) must fall back to the static catalog")
			XCTAssertEqual(result.modelsSource, .staticFallback)
			XCTAssertTrue(
				result.diagnostics.contains(.modelsUnparseable),
				"a parse failure must be DIAGNOSED, not silent: \(malformed)"
			)
		}
	}

	/// The core rule, stated as bluntly as possible.
	func testAdvertisedButUnknownModelIsNeverOffered() {
		let result = project(models: ["opus", "some-model-this-app-has-no-code-for"])
		XCTAssertEqual(
			result.effectiveModels, ["opus"],
			"the unknown advertised model must be DROPPED, not added — intersection, never union"
		)
		XCTAssertFalse(result.effectiveModels.contains("some-model-this-app-has-no-code-for"))
		XCTAssertTrue(result.diagnostics.contains(.modelsDroppedUnknown(count: 1)))
	}

	/// A runtime sharing NO model with the app yields an EMPTY intersection.
	///
	/// This previously restored the full static catalog, which offered models the
	/// runtime never advertised — a successful parse turned into a widening. Static
	/// fallback is reserved for absent or unparseable input, where the app knows
	/// nothing; here it knows exactly what was advertised and that none of it matches.
	func testEntirelyUnknownAdvertisementYieldsAnEmptyIntersection() {
		let result = project(models: ["mystery-a", "mystery-b"])
		XCTAssertEqual(result.effectiveModels, [],
					   "a successful parse with zero overlap is an EMPTY intersection, not a fallback")
		XCTAssertEqual(result.modelsSource, .runtimeIntersected,
					   "the parse succeeded — reporting `.staticFallback` would misdescribe it")
		XCTAssertTrue(result.diagnostics.contains(.modelsIntersectionEmpty(advertised: 2)))
	}

	/// The boundary between "empty intersection" and "static fallback", stated as the
	/// contrast that matters: only ABSENT or UNPARSEABLE input restores the catalog.
	func testOnlyAbsentOrUnparseableInputRestoresTheStaticCatalog() {
		for restoring: Any? in [nil, "not json", 42] {
			let result = project(models: restoring)
			XCTAssertEqual(result.effectiveModels, staticCatalog,
						   "absent/unparseable input must restore the catalog: \(String(describing: restoring))")
			XCTAssertEqual(result.modelsSource, .staticFallback)
		}
		// An EMPTY array carries no advertisement, so it is fallback, not narrowing —
		// it belongs with the absent case above, not here.
		for narrowing: Any in [["mystery"], ["opus"]] {
			let result = project(models: narrowing)
			XCTAssertNotEqual(
				result.effectiveModels, staticCatalog,
				"a parseable advertisement must never restore the full catalog: \(narrowing)"
			)
		}
	}

	/// The property, over every shape at once. A union introduced anywhere in the
	/// parser — a new branch, a new wrapper key — fails here even if no specific
	/// example test covers that shape.
	func testProjectionIsAlwaysASubsetOfTheStaticCatalog() {
		let inputs: [Any?] = [
			nil, 42, "junk", ["opus"], ["unknown"], ["opus", "unknown"],
			[["model": "sonnet"]], [["model": "nope"]], ["models": ["haiku", "nope"]],
			"[\"opus\",\"nope\"]", [String: Any](), [[String: Any]()], true,
		]
		let allowed = Set(staticCatalog)
		for input in inputs {
			let offered = Set(project(models: input).effectiveModels)
			XCTAssertTrue(
				offered.isSubset(of: allowed),
				"input \(String(describing: input)) produced \(offered.subtracting(allowed)) — a UNION"
			)
		}
	}

	/// Diagnostics must not become an exfiltration path for runtime payload (§8).
	func testDiagnosticsCarryNoRuntimePayload() {
		let secretish = "claude-internal-rollout-abcdef123456"
		let result = project(models: [secretish, "opus"])
		let rendered = result.diagnostics.map(\.description).joined(separator: " ")
		XCTAssertFalse(rendered.contains(secretish),
					   "a diagnostic must record SHAPES and COUNTS, never runtime-advertised values")
		XCTAssertFalse(rendered.contains("claude-internal"))
	}

	// MARK: - Fast mode

	func testFastModeParsesAndFallsBackConservatively() {
		XCTAssertEqual(project(fastMode: ["enabled": true]).fastMode, .enabled)
		XCTAssertEqual(project(fastMode: ["enabled": false]).fastMode, .disabled)
		XCTAssertEqual(project(fastMode: true).fastMode, .enabled)

		let absent = project(fastMode: nil)
		XCTAssertEqual(absent.fastMode, .unknown, "absent must not read as a positive observation")
		XCTAssertFalse(absent.fastMode.isOffered)
		XCTAssertTrue(absent.diagnostics.contains(.fastModeAbsent))

		let malformed = project(fastMode: 17)
		XCTAssertEqual(malformed.fastMode, .unknown)
		XCTAssertFalse(malformed.fastMode.isOffered, "unknown must never offer fast mode")
		XCTAssertTrue(malformed.diagnostics.contains(.fastModeUnparseable))
	}

	/// `.unknown` and `.disabled` must stay distinct: collapsing them would let a
	/// parse failure read as a runtime observation.
	func testUnknownFastModeIsDistinctFromDisabled() {
		XCTAssertNotEqual(ClaudeFastModeState.unknown, ClaudeFastModeState.disabled)
		XCTAssertFalse(ClaudeFastModeState.unknown.isOffered)
		XCTAssertFalse(ClaudeFastModeState.disabled.isOffered)
	}

	// MARK: - Effort

	func testRecognizedEffortHintNarrowsAndUnknownFallsBackConservatively() {
		let recognized = project(fastMode: ["enabled": true, "effort": "high"])
		XCTAssertEqual(recognized.effectiveEffortLevels, [.high])

		let unknown = project(fastMode: ["enabled": true, "effort": "ludicrous"])
		XCTAssertEqual(unknown.effectiveEffortLevels, staticEfforts,
					   "an unrecognised effort must fall back to the full static catalog, never to empty")
		XCTAssertTrue(unknown.diagnostics.contains(.effortUnrecognized))
	}

	func testEffortLevelOutsideTheStaticCatalogIsNeverIntroduced() {
		let narrow: [ClaudeCodeEffortLevel] = [.low, .medium]
		let result = ClaudeDynamicCapabilityProjector.project(
			staticModelCatalog: staticCatalog,
			staticEffortCatalog: narrow,
			modelsValue: nil,
			fastModeStateValue: ["effort": "max"], parseEffort: { ClaudeCodeEffortLevel.parse($0) })
		XCTAssertEqual(result.effectiveEffortLevels, narrow,
					   "`max` is outside this catalog and must not be introduced by the runtime")
		XCTAssertTrue(result.diagnostics.contains(.effortUnrecognized))
	}


}

private enum ClaudeCodeEffortLevel: String, CaseIterable, Sendable {
    case max, xhigh, high, medium, low
    static func parse(_ raw: String) -> Self? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self(rawValue: normalized == "x-high" ? "xhigh" : normalized)
    }
}
private typealias ClaudeDynamicCapabilities = AgentClaudeCapabilities.ClaudeDynamicCapabilities<ClaudeCodeEffortLevel>
private typealias ClaudeDynamicCapabilityProjector = AgentClaudeCapabilities.ClaudeDynamicCapabilityProjector<ClaudeCodeEffortLevel>
