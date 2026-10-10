import XCTest
import AgentClaudeCapabilities

final class ClaudeInitializeValidationTests: XCTestCase {
    private var response: [String: Any] {
        ["commands": [["name": "compact"]], "output_style": "default",
         "available_output_styles": ["default"], "pid": 4242]
    }
    func testTypedContractAllowsAdditiveFieldsWithoutSessionID() {
        var value = response; value["future"] = ["anything": true]
        XCTAssertTrue(ClaudeInitializeResponseWellFormedness.isWellFormed(value))
        XCTAssertNil(value["session_id"])
        XCTAssertEqual(ClaudeInitializeResponseWellFormedness.violations(of: [:]), [.empty])
    }
    func testEachRequiredFieldFailsIndependentlyAndErrorsHaveStableOrder() {
        for field in ClaudeInitializeResponseWellFormedness.requiredFields {
            var value = response; value.removeValue(forKey: field)
            XCTAssertEqual(ClaudeInitializeResponseWellFormedness.violations(of: value), [.missingRequiredField(field)])
        }
        XCTAssertEqual(ClaudeInitializeResponseWellFormedness.violations(of: ["pid": true]), [
            .missingRequiredField("available_output_styles"), .missingRequiredField("commands"),
            .missingRequiredField("output_style"), .wrongType(field: "pid", expected: "positive integer")])
    }
    func testEveryTypedFieldRejectsMalformedValues() {
        for (field, value): (String, Any) in [("pid", true), ("pid", 0), ("pid", "4242"),
            ("commands", [["name": ""]]), ("commands", [1]), ("agents", [["other": "x"]]),
            ("output_style", 1), ("available_output_styles", [1]), ("account", "account")] {
            var invalid = response; invalid[field] = value
            XCTAssertFalse(ClaudeInitializeResponseWellFormedness.isWellFormed(invalid), field)
        }
        var whitespace = response; whitespace["commands"] = [["name": " "]]
        XCTAssertTrue(ClaudeInitializeResponseWellFormedness.isWellFormed(whitespace), "legacy predicate checks emptiness without trimming")
    }
    func testPermissionEchoIsRequiredAndCaseInsensitiveWithoutTrimming() {
        XCTAssertEqual(ClaudePermissionModeRoundTrip.classify(requestedMode: "default", response: ["mode": "DEFAULT"]), .confirmed(mode: "DEFAULT"))
        XCTAssertEqual(ClaudePermissionModeRoundTrip.classify(requestedMode: "default", response: [:]), .succeededWithoutEcho(requested: "default"))
        XCTAssertEqual(ClaudePermissionModeRoundTrip.classify(requestedMode: "default", response: ["mode": " default "]), .modeMismatch(requested: "default", returned: " default "))
        XCTAssertFalse(ClaudePermissionModeRoundTrip.notAttempted.satisfiesValidation)
        XCTAssertFalse(ClaudePermissionModeRoundTrip.succeededWithoutEcho(requested: "default").satisfiesValidation)
        XCTAssertFalse(ClaudePermissionModeRoundTrip.modeMismatch(requested: "default", returned: "other").satisfiesValidation)
        XCTAssertTrue(ClaudePermissionModeRoundTrip.confirmed(mode: "default").satisfiesValidation)
    }
}
