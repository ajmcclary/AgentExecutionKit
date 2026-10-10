import Foundation
import ProcessStreamFraming

/// ACP-specific fail-closed NDJSON framing. No overflow-retained tail may become a
/// frame. Completed lines are independently bounded, including mid-chunk emissions.
public struct ACPStdoutDecoder: Sendable {
	public struct Limits: Sendable {
		public let maxLineBytes: Int
		public let maxCarryBytes: Int
		public let tailRetainBytes: Int
		public init(maxLineBytes: Int, maxCarryBytes: Int, tailRetainBytes: Int) {
			self.maxLineBytes = maxLineBytes; self.maxCarryBytes = maxCarryBytes; self.tailRetainBytes = tailRetainBytes
		}
	}
	public enum Event: Sendable, Equatable { case line(Data), failure(String) }
	private var framer: LineFramer
	public private(set) var failed = false
	public init(limits: Limits? = nil) {
		framer = limits.map { LineFramer(limits: .init(maxLineBytes: $0.maxLineBytes, maxCarryBytes: $0.maxCarryBytes, tailRetainBytes: $0.tailRetainBytes)) } ?? LineFramer()
	}
	public mutating func feed(_ data: Data) -> [Event] {
		guard !failed else { return [] }
		var overflow = false, lines: [Data] = []
		framer.feed(data, onDiagnostic: { if case .overflow = $0 { overflow = true } }, onLine: { lines.append($0) })
		var result: [Event] = []
		for line in lines {
			guard line.count <= framer.limits.maxLineBytes else {
				failed = true
				result.append(.failure("ACP frame exceeded the \(framer.limits.maxLineBytes)-byte logical-line limit"))
				return result
			}
			if let trimmed = trimmedASCIIWhitespace(line), !trimmed.isEmpty { result.append(.line(trimmed)) }
		}
		if overflow {
			failed = true
			result.append(.failure("ACP stdout logical line overflowed the framing limit; no bytes of it may be interpreted as a frame"))
		}
		return result
	}
}
