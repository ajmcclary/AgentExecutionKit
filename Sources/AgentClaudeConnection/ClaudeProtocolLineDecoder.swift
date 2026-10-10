import Foundation
import AgentClaudeProtocol
import ProcessStreamFraming

/// Claude-specific recovery policy above neutral process/framing primitives.
/// Observations preserve order; no logging, presentation or lifecycle authority.
public struct ClaudeProtocolLineDecoder: Sendable {
	public struct Limits: Sendable {
		public let concatenatedRecoveryBytes: Int
		public let tailRecoveryScanBytes: Int
		public init(concatenatedRecoveryBytes: Int = 2 * 1024 * 1024, tailRecoveryScanBytes: Int = 256 * 1024) {
			self.concatenatedRecoveryBytes = max(0, concatenatedRecoveryBytes)
			self.tailRecoveryScanBytes = max(1, tailRecoveryScanBytes)
		}
	}
	public enum Event: Sendable {
		case message(ClaudeNativeProtocolCodec.InboundMessage)
		case concatenatedRecoverySkipped(byteCount: Int, threshold: Int)
		case recoveredSegment(Data)
		case recoveredSegmentSkipped(preview: String, error: String)
		case recovered(segments: Int, recoveredSegments: Int)
		case recoveredTail(startOffset: Int, byteCount: Int, preview: String)
		case recoveredJSONStringControlChars(Data)
		case recoveredPlaintext(String)
		case skipped(ClaudeNativeProtocolCodec.CodecError, preview: String)
		case failed(error: String, preview: String)
	}
	public typealias Codec = @Sendable (Data) throws -> ClaudeNativeProtocolCodec.InboundMessage?
	private let limits: Limits
	private let codec: Codec
	public init(limits: Limits = .init(), codec: @escaping Codec = { try ClaudeNativeProtocolCodec.decodeLine($0) }) {
		self.limits = limits; self.codec = codec
	}
	public func decode(_ line: Data, allowPlaintext: Bool) -> [Event] {
		do { return try codec(line).map { [.message($0)] } ?? [] }
		catch let error as ClaudeNativeProtocolCodec.CodecError {
			var events: [Event] = []
			if error == .invalidJSON {
				if recoverConcatenated(line, events: &events) || recoverTail(line, events: &events)
					|| recoverControlCharacters(line, events: &events) { return events }
				if allowPlaintext, let text = Self.recoverablePlaintextAssistantFragment(from: line) {
					events.append(.recoveredPlaintext(text)); return events
				}
			}
			events.append(.skipped(error, preview: Self.preview(line, limit: 512)))
			return events
		} catch { return [.failed(error: error.localizedDescription, preview: Self.preview(line, limit: 512))] }
	}
	private func recoverConcatenated(_ line: Data, events: inout [Event]) -> Bool {
		guard line.count <= limits.concatenatedRecoveryBytes else {
			events.append(.concatenatedRecoverySkipped(byteCount: line.count, threshold: limits.concatenatedRecoveryBytes)); return false
		}
		let segments = JSONStreamFramer.splitConcatenatedObjects(line).frames
		guard segments.count > 1 else { return false }
		var recovered = 0
		for segment in segments {
			do {
				guard let inbound = try codec(segment) else { continue }
				recovered += 1; events.append(.recoveredSegment(segment)); events.append(.message(inbound))
			} catch { events.append(.recoveredSegmentSkipped(preview: Self.preview(segment, limit: 256), error: error.localizedDescription)) }
		}
		if recovered > 0 { events.append(.recovered(segments: segments.count, recoveredSegments: recovered)); return true }
		return false
	}
	private func recoverTail(_ line: Data, events: inout [Event]) -> Bool {
		guard !line.isEmpty else { return false }
		let offset = max(0, line.count - limits.tailRecoveryScanBytes)
		let window = offset > 0 ? Data(line.suffix(limits.tailRecoveryScanBytes)) : line
		var candidates = Self.jsonObjectStartOffsets(in: window)
		if candidates.first == 0, offset == 0 { candidates.removeFirst() }
		// Prefer the rightmost valid suffix; no earlier frames are replayed.
		for candidate in candidates.reversed() {
			let absolute = offset + candidate
			let suffix = Data(line.suffix(from: line.startIndex + absolute))
			do {
				guard let inbound = try codec(suffix) else { continue }
				events.append(.recoveredTail(startOffset: absolute, byteCount: suffix.count,
					preview: makeUTF8Sample(from: suffix, limit: 180)?.0 ?? "<non-utf8>"))
				events.append(.message(inbound)); return true
			} catch { continue }
		}
		return false
	}
	private static let marker = Array("{\"type\":\"".utf8)
	private static func jsonObjectStartOffsets(in data: Data) -> [Int] {
		guard data.count >= marker.count else { return [] }
		var offsets: [Int] = []
		data.withUnsafeBytes { buffer in
			guard let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
			for index in 0...(data.count - marker.count) {
				if marker.indices.allSatisfy({ bytes[index + $0] == marker[$0] }) { offsets.append(index) }
			}
		}
		return offsets
	}
	private func recoverControlCharacters(_ line: Data, events: inout [Event]) -> Bool {
		guard let repaired = repairJSONStringControlCharacters(line),
			let inbound = try? codec(repaired) else { return false }
		events.append(.recoveredJSONStringControlChars(repaired)); events.append(.message(inbound)); return true
	}
	private static func preview(_ data: Data, limit: Int) -> String { String(data: data.prefix(limit), encoding: .utf8) ?? "<non-utf8>" }
	public static func recoverablePlaintextAssistantFragment(from line: Data) -> String? {
		guard let raw = String(data: line, encoding: .utf8) else { return nil }
		let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, text.count >= 40, !text.contains("\t"), !text.hasPrefix("{"),
			!text.hasPrefix("["), !text.contains("{\"type\":\""), !text.hasPrefix("."), !text.hasPrefix("/") else { return nil }
		let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
		guard letters >= 24 else { return nil }
		let words = text.split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 4 }.count
		guard words >= 4 else { return nil }
		let braces = text.unicodeScalars.filter { "{}[];".unicodeScalars.contains($0) }.count
		return braces <= 8 ? text : nil
	}
}
