import Foundation
import XCTest
import AgentACPRPC
import AgentACPProtocol

final class ACPProtocolTests: XCTestCase {
	private func message(_ text: String) throws -> ACPJSONRPCMessage { try .init(data: Data(text.utf8)) }
	func testRequestNotificationResponseAndUnknownClassification() throws {
		let request = try message(#"{"id":"1","method":"session/request_permission","params":{"sessionId":" raw "}}"#)
		XCTAssertEqual(request.kind, .request); XCTAssertEqual(request.id, .string("1"))
		XCTAssertEqual(try request.params.dictionary()["sessionId"] as? String, " raw ")
		XCTAssertEqual(try message(#"{"method":"session/update"}"#).kind, .notification)
		XCTAssertEqual(try message(#"{"id":1,"result":{}}"#).kind, .response)
		XCTAssertEqual(try message(#"{"future":true}"#).kind, .unknown)
	}
	func testResultWinsErrorAndScalarResultIsMissing() throws {
		let good = try message(#"{"id":1,"result":{"ok":true},"error":{"message":"ignored"}}"#)
		guard case .result(let result) = good.response else { return XCTFail("Expected object result") }
		XCTAssertEqual(try result.dictionary()["ok"] as? Bool, true)
		guard case .missing = try message(#"{"id":1,"result":42}"#).response else { return XCTFail("Expected missing object") }
	}
	func testExactErrorProjectionAndNestedDetail() throws {
		let value = try message(#"{"id":1,"error":{"code":18446744073709519014,"message":"base","data":{"cause":{"message":"detail"}}}}"#)
		guard case .failure(let text, let code) = value.response else { return XCTFail("Expected failure") }
		XCTAssertEqual(text, "base: detail"); XCTAssertNil(code)
	}
	func testMalformedJSONAndNonObjectsAreRejected() {
		for text in ["no", "[]", "null", "42", "{broken}"] { XCTAssertThrowsError(try message(text)) }
	}
	func testBooleanAndNullIDsCannotBecomeRequests() throws {
		for id in ["true", "false", "null"] {
			let value = try message("{\"id\":\(id),\"method\":\"update\",\"params\":7}")
			XCTAssertEqual(value.kind, .notification); XCTAssertNil(value.id)
			XCTAssertTrue(try value.params.dictionary().isEmpty)
		}
	}
	func testRawBytesUnknownFieldsLargeIntegersAndFreshGraphsSurvive() async throws {
		let raw = Data(#"{"id":1,"result":{"large":9007199254740993},"future":[null,true,"hé 🧭"]}"#.utf8)
		let value = try ACPJSONRPCMessage(data: raw)
		var first = try value.payload.dictionary(); first["future"] = "changed"
		XCTAssertTrue(try value.payload.dictionary()["future"] is [Any])
		let transferred = await Task { value.payload.data }.value
		XCTAssertEqual(transferred, raw)
		guard case .result(let result) = value.response else { return XCTFail("Expected result") }
		XCTAssertEqual((try result.dictionary()["large"] as? NSNumber)?.stringValue, "9007199254740993")
	}
	func testRequestEncodingKeepsTypedIDAndParams() throws {
		let payload = try ACPJSONRPCMessage.request(id: .string(" raw "), method: "session/prompt", params: .init(object: ["value": NSNull()]))
		let object = try payload.dictionary()
		XCTAssertEqual(object["jsonrpc"] as? String, "2.0"); XCTAssertEqual(object["id"] as? String, " raw ")
		XCTAssertTrue((object["params"] as? [String: Any])?["value"] is NSNull)
	}
	func testBytewiseUnicodeFragmentationCRLFAndBlankLines() {
		var decoder = ACPStdoutDecoder(); var events: [ACPStdoutDecoder.Event] = []
		let text = " \r\n{\"text\":\"hé 🧭\\nquoted\\\"\"}\r\n\t\n"
		for byte in text.utf8 { events += decoder.feed(Data([byte])) }
		XCTAssertEqual(events, [.line(Data("{\"text\":\"hé 🧭\\nquoted\\\"\"}".utf8))])
		XCTAssertFalse(decoder.failed)
	}
	func testUnterminatedFrameRemainsBufferedUntilNewline() {
		var decoder = ACPStdoutDecoder()
		XCTAssertTrue(decoder.feed(Data("{}".utf8)).isEmpty)
		XCTAssertEqual(decoder.feed(Data([10])), [.line(Data("{}".utf8))])
	}
	func testOversizedCompletedLineRejectsFollowingFramesInSameChunk() {
		var decoder = ACPStdoutDecoder(limits: .init(maxLineBytes: 32, maxCarryBytes: 64, tailRetainBytes: 16))
		let values = decoder.feed(Data(("{}\n" + String(repeating: "x", count: 33) + "\n{\"forged\":true}\n").utf8))
		XCTAssertEqual(values, [.line(Data("{}".utf8)), .failure("ACP frame exceeded the 32-byte logical-line limit")])
		XCTAssertTrue(decoder.failed); XCTAssertTrue(decoder.feed(Data("{}\n".utf8)).isEmpty)
	}
	func testOverflowRetainedTailCanNeverCompleteOrRecover() {
		var decoder = ACPStdoutDecoder(limits: .init(maxLineBytes: 32, maxCarryBytes: 64, tailRetainBytes: 16))
		let values = decoder.feed(Data((String(repeating: "x", count: 40) + "{\"id\":1}").utf8))
		XCTAssertEqual(values, [.failure("ACP stdout logical line overflowed the framing limit; no bytes of it may be interpreted as a frame")])
		XCTAssertTrue(decoder.feed(Data("\n{\"result\":{}}\n".utf8)).isEmpty)
	}
}
