import Foundation
import XCTest
import AgentACPRPC
import AgentACPProtocol
import AgentACPPermissions

final class ACPPermissionValidationTests: XCTestCase {
	private let policy = ACPPermissionPolicy(allowOnce: [.kind("allow_once")], allowSession: [.kind("allow_always")],
		reject: [], sessionAffordance: [.kind("allow_always")])
	private func params(tool: [String: Any] = ["toolCallId": "tool"], options: [[String: Any]] = [["optionId": "once", "kind": "allow_once"]]) -> [String: Any] {
		["sessionId": " session ", "toolCall": tool, "options": options]
	}
	private func validate(_ object: [String: Any]) -> Result<ACPPermissionRequest, ACPPermissionRefusal> {
		ACPPermissionValidation.validate(id: .string("raw"), params: object, boundSessionID: " session ", policy: policy)
	}
	func testSessionBindingMustBeExactAndPresent() throws {
		let good = try validate(params()).get(); XCTAssertEqual(good.sessionID, " session ")
		for id: Any in ["session", "foreign", NSNull(), 1] {
			var object = params(); object["sessionId"] = id
			XCTAssertThrowsError(try validate(object).get()) { XCTAssertEqual($0 as? ACPPermissionRefusal, .foreignSession) }
		}
		XCTAssertThrowsError(try ACPPermissionValidation.validate(id: .int(1), params: params(), boundSessionID: nil, policy: policy).get())
	}
	func testByteBoundedToolIdentityTitleKindAndMalformedTypes() throws {
		let good = try validate(params(tool: ["toolCallId": " tool ", "title": String(repeating: "é", count: 2048), "kind": " EDIT "])).get()
		XCTAssertEqual(good.toolCallID, "tool"); XCTAssertEqual(good.toolKind, "edit")
		for tool: [String: Any] in [
			[:], ["toolCallId": ""], ["toolCallId": String(repeating: "x", count: 513)],
			["toolCallId": "tool", "title": String(repeating: "é", count: 2049)],
			["toolCallId": "tool", "title": "a" + String(repeating: "\u{301}", count: 3000)],
			["toolCallId": "tool", "title": 4], ["toolCallId": "tool", "kind": String(repeating: "x", count: 129)]
		] { XCTAssertThrowsError(try validate(params(tool: tool)).get()) }
		let absent = try validate(params(tool: ["toolCallId": "tool", "title": NSNull(), "kind": NSNull()])).get()
		XCTAssertNil(absent.toolTitle); XCTAssertNil(absent.toolKind)
	}
	func testUniqueBoundedOptionsAndUnknownKinds() throws {
		for options: [[String: Any]] in [
			[], [["optionId": "id"]], [["optionId": "", "kind": "allow_once"]],
			[["optionId": "One", "kind": "allow_once"], ["optionId": " one ", "kind": "allow_once"]],
			[["optionId": String(repeating: "x", count: 257), "kind": "allow_once"]],
			[["optionId": "id", "kind": String(repeating: "x", count: 129)]],
			(0..<33).map { ["optionId": String($0), "kind": "allow_once"] }
		] { XCTAssertThrowsError(try validate(params(options: options)).get()) }
		let result = try validate(params(options: [["optionId": " future ", "kind": " Future ", "extras": String(repeating: "x", count: 100_000)]])).get()
		XCTAssertEqual(result.options, [.init(optionID: "future", kind: "Future")]); XCTAssertNil(result.sessionScopedOptionID)
	}
	func testAffordanceDependsOnAdvertisedSessionOption() throws {
		let once = try validate(params()).get(); XCTAssertNil(once.sessionScopedOptionID)
		let always = try validate(params(options: [["optionId": "raw", "kind": "Allow_Always"]])).get()
		XCTAssertEqual(always.sessionScopedOptionID, "raw")
	}
	func testTopLevelStringsUseVerbatimBytesAndNestedEscapesAreBounded() {
		let text = String(repeating: "\"\\/", count: 1000)
		XCTAssertEqual(ACPBoundedJSON.serialized(text, byteLimit: text.utf8.count), text)
		XCTAssertEqual(ACPBoundedJSON.serialized(text, byteLimit: text.utf8.count - 1), "[omitted: rawInput exceeds \(text.utf8.count - 1) bytes]")
		let object = ["value": String(repeating: "\"", count: 40_000)]
		XCTAssertEqual(ACPBoundedJSON.serialized(object, byteLimit: 65_536), "[omitted: rawInput exceeds 65536 bytes]")
	}
	func testPrettyPrintedActualSizeCannotExceedLimitDespiteCompactEstimate() throws {
		let object = ["array": Array(repeating: "small", count: 50)]
		let compactEstimate = ACPBoundedJSON.estimatedJSONByteSize(object, limit: 10_000)
		let pretty = try XCTUnwrap(ACPBoundedJSON.serializeJSON(object))
		XCTAssertGreaterThan(pretty.utf8.count, compactEstimate)
		XCTAssertEqual(ACPBoundedJSON.serialized(object, byteLimit: compactEstimate), "[omitted: rawInput exceeds \(compactEstimate) bytes]")
	}
	func testEstimateBoundsCompactEncodingAcrossEscapesAndNonASCII() throws {
		for text in ["a", "\"", "\\", "/", "\u{0}", "\n", "é", "🧭"] {
			let object = ["value": [text]]
			let actual = try JSONSerialization.data(withJSONObject: object).count
			XCTAssertGreaterThanOrEqual(ACPBoundedJSON.estimatedJSONByteSize(object, limit: 10_000), actual)
		}
	}
	func testOversizedRawInputProjectsMarkerAndNoInputProjectsNil() throws {
		let value = try validate(params(tool: ["toolCallId": "tool", "rawInput": String(repeating: "x", count: 70_000)])).get()
		XCTAssertEqual(value.rawInputJSON, "[omitted: rawInput exceeds 65536 bytes]")
		XCTAssertNil(ACPBoundedJSON.serialized(NSNull(), byteLimit: 10))
		XCTAssertNil(ACPBoundedJSON.serialized(Date(), byteLimit: 1000))
	}
}
