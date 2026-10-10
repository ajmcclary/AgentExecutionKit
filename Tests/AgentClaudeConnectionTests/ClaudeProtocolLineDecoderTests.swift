import Foundation
import XCTest
import AgentClaudeConnection
import AgentClaudeProtocol

final class ClaudeProtocolLineDecoderTests: XCTestCase {
	private let first = #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}"#
	private let second = #"{"type":"keep_alive"}"#
	private func decode(_ text: String, allow: Bool = false, limits: ClaudeProtocolLineDecoder.Limits = .init()) -> [ClaudeProtocolLineDecoder.Event] {
		ClaudeProtocolLineDecoder(limits: limits).decode(Data(text.utf8), allowPlaintext: allow)
	}
	private func labels(_ events: [ClaudeProtocolLineDecoder.Event]) -> [String] {
		events.map { event in
			switch event {
			case .message(.streamPayload): return "stream"
			case .message(.keepAlive): return "keepAlive"
			case .message(.controlRequest): return "request"
			case .message(.controlResponse): return "response"
			case .message(.controlCancelRequest): return "cancel"
			case .concatenatedRecoverySkipped: return "oversized"
			case .recoveredSegment: return "segment"
			case .recoveredSegmentSkipped: return "segmentSkipped"
			case .recovered: return "recovered"
			case .recoveredTail: return "tail"
			case .recoveredJSONStringControlChars: return "controlChars"
			case .recoveredPlaintext: return "plaintext"
			case .skipped: return "skipped"
			case .failed: return "failed"
			}
		}
	}
	func testNormalFramesAndBlankNoiseKeepCodecBehavior() {
		XCTAssertEqual(labels(decode(first)), ["stream"])
		XCTAssertEqual(labels(decode(second)), ["keepAlive"])
		XCTAssertTrue(decode(" \n").isEmpty)
		XCTAssertEqual(labels(decode(#"{"type":"future","unknown":true}"#)), ["stream"])
	}
	func testControlFramesUseImmutableSharedContracts() throws {
		let events = decode(#"{"type":"control_request","request_id":"raw","request":{"subtype":"can_use_tool","future":9007199254740993}}"#)
		guard case .message(.controlRequest(let request)) = try XCTUnwrap(events.first) else { return XCTFail("missing request") }
		XCTAssertEqual(request.requestID, "raw"); XCTAssertEqual(request.subtype, "can_use_tool")
		XCTAssertEqual((try request.request.dictionary()["future"] as? NSNumber)?.int64Value, 9007199254740993)
		XCTAssertEqual(labels(decode(#"{"type":"control_response","response":{"subtype":"success","request_id":"r","response":{}}}"#)), ["response"])
		XCTAssertEqual(labels(decode(#"{"type":"control_cancel_request","request_id":"r"}"#)), ["cancel"])
	}
	func testConcatenatedFramesPreserveSegmentsAndObservationOrder() {
		XCTAssertEqual(labels(decode(first + second)), ["segment", "stream", "segment", "keepAlive", "recovered"])
		guard case .recovered(let segments, let count) = decode(first + second).last else { return XCTFail("missing summary") }
		XCTAssertEqual(segments, 2); XCTAssertEqual(count, 2)
	}
	func testMixedConcatenatedRecoverySkipsUnsupportedSegmentButKeepsValidOne() {
		XCTAssertEqual(labels(decode("[]" + first + #"{"type":"control_request"}"#)), ["segment", "stream", "segmentSkipped", "recovered"])
	}
	func testTailRecoveryPrefersRightmostFrameAndPreservesByteOffset() throws {
		let prefix = "broken é " + first + " garbage "
		let events = decode(prefix + second, limits: .init(concatenatedRecoveryBytes: 0))
		XCTAssertEqual(labels(events), ["oversized", "tail", "keepAlive"])
		guard case .recoveredTail(let offset, let size, _) = try XCTUnwrap(events.dropFirst().first) else { return XCTFail("no tail") }
		XCTAssertEqual(offset, prefix.utf8.count); XCTAssertEqual(size, second.utf8.count)
	}
	func testTailWindowIsBoundedAndFindsMarkerAtWindowStart() {
		let limits = ClaudeProtocolLineDecoder.Limits(concatenatedRecoveryBytes: 0, tailRecoveryScanBytes: second.utf8.count)
		XCTAssertEqual(labels(decode(String(repeating: "x", count: 100) + second, limits: limits)), ["oversized", "tail", "keepAlive"])
		XCTAssertEqual(labels(decode(second + String(repeating: "x", count: 100), limits: limits)), ["oversized", "skipped"])
	}
	func testRecoveryLimitsRetainShippingDefaultsAndInclusiveConcatenationBound() {
		let defaults = ClaudeProtocolLineDecoder.Limits()
		XCTAssertEqual(defaults.concatenatedRecoveryBytes, 2 * 1024 * 1024)
		XCTAssertEqual(defaults.tailRecoveryScanBytes, 256 * 1024)
		let line = first + second
		XCTAssertEqual(labels(decode(line, limits: .init(concatenatedRecoveryBytes: line.utf8.count))), ["segment", "stream", "segment", "keepAlive", "recovered"])
		XCTAssertEqual(labels(decode(line, limits: .init(concatenatedRecoveryBytes: line.utf8.count - 1))), ["oversized", "tail", "keepAlive"])
	}
	func testLiteralControlCharactersRepairAfterTailRecovery() throws {
		let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"# + "\n\tworld" + #""}]}}"#
		XCTAssertEqual(labels(decode(line)), ["stream"], "Shipping codec already accepts/repairs this input")
		let strict = ClaudeProtocolLineDecoder(codec: { data in
			if data.contains(0x0A) || data.contains(0x09) { throw ClaudeNativeProtocolCodec.CodecError.invalidJSON }
			return try ClaudeNativeProtocolCodec.decodeLine(data)
		})
		let events = strict.decode(Data(line.utf8), allowPlaintext: false)
		XCTAssertEqual(labels(events), ["controlChars", "stream"])
		guard case .message(.streamPayload(let payload)) = try XCTUnwrap(events.last) else { return XCTFail("missing payload") }
		XCTAssertNotNil(try payload.dictionary()["message"])
	}
	func testPlaintextNeedsAnActiveTurnAndNeverCreatesLifecycleCompletion() {
		let line = "The investigation was exploring why tool events appeared while assistant text never rendered."
		XCTAssertEqual(labels(decode(line)), ["skipped"])
		XCTAssertEqual(labels(decode(line, allow: true)), ["plaintext"])
	}
	func testPlaintextRejectsCodeJsonShortAndInvalidUtf8() {
		for line in ["Short text", ".runningStatusText = nil\n\tviewModel?.setAgentRunActive(session.tabID, isActive: false)", String(repeating: "a ", count: 40), first, " /this narrative includes enough substantial words to otherwise qualify"] {
			XCTAssertNil(ClaudeProtocolLineDecoder.recoverablePlaintextAssistantFragment(from: Data(line.utf8)), line)
		}
		XCTAssertNil(ClaudeProtocolLineDecoder.recoverablePlaintextAssistantFragment(from: Data([0xff, 0xfe])))
	}
	func testPlaintextUnicodeAndWhitespaceRemainPreservedAfterTrimming() {
		let line = "  These substantial Unicode words describe naïve résumé preparation for testing. \n"
		XCTAssertEqual(ClaudeProtocolLineDecoder.recoverablePlaintextAssistantFragment(from: Data(line.utf8)), line.trimmingCharacters(in: .whitespacesAndNewlines))
	}
	func testUnsupportedValidJsonDoesNotFallBackToEmbeddedTail() {
		XCTAssertEqual(labels(decode(#"{"type":"control_request","nested":{"type":"keep_alive"}}"#)), ["skipped"])
	}
	func testNonUtf8SkippedPreviewAndUnexpectedCodecFailure() throws {
		let events = ClaudeProtocolLineDecoder().decode(Data([0xff]), allowPlaintext: true)
		guard case .skipped(.invalidJSON, let preview) = try XCTUnwrap(events.last) else { return XCTFail("wrong skip") }
		XCTAssertEqual(preview, "<non-utf8>")
		struct Failure: LocalizedError { var errorDescription: String? { "fixture failure" } }
		let failing = ClaudeProtocolLineDecoder(codec: { _ in throw Failure() })
		guard case .failed(let error, let snippet) = try XCTUnwrap(failing.decode(Data("wire".utf8), allowPlaintext: false).first) else { return XCTFail("missing failure") }
		XCTAssertEqual(error, "fixture failure"); XCTAssertEqual(snippet, "wire")
	}
	func testSkippedPreviewIsBoundedTo512Bytes() throws {
		let line = String(repeating: "x", count: 700)
		guard case .skipped(_, let preview) = try XCTUnwrap(decode(line).last) else { return XCTFail("missing skip") }
		XCTAssertEqual(preview, String(line.prefix(512)))
	}
}
