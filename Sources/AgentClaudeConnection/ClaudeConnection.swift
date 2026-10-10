import Foundation
import AgentNativeProcessTransport
import ProcessStreamFraming

/// Actor-confined native connection. Transport callbacks deliver captured
/// generations to the owner, which feeds bytes back here synchronously. No
/// configuration resolution, permission, session, UI or logging policy lives here.
public final class ClaudeConnection {
	public struct Errors: Sendable {
		public let unavailable: @Sendable () -> any Error
		public let inputWriteFailed: @Sendable (String) -> any Error
		public init(unavailable: @escaping @Sendable () -> any Error, inputWriteFailed: @escaping @Sendable (String) -> any Error) {
			self.unavailable = unavailable; self.inputWriteFailed = inputWriteFailed
		}
	}
	public enum Event: Sendable {
		case framing(LineFramer.Diagnostic)
		case inboundLine(Data)
		case protocolEvent(ClaudeProtocolLineDecoder.Event)
		case stderr(Data)
	}
	public struct DecodeFailure: Sendable { public let preview: String; public let error: String }
	private let transport: AgentNativeProcessTransport
	private let decoder: ClaudeProtocolLineDecoder
	private let errors: Errors
	private let framingLimits: LineFramer.Limits
	private var framer: LineFramer
	public private(set) var stderrTail = Data()
	public private(set) var decodeFailure: DecodeFailure?
	public var generation: UInt64 { transport.generation }
	public var hasProcess: Bool { transport.hasProcess }
	public var pid: Int32? { transport.pid }
	public init(lifecycle: AgentNativeProcessTransport.Lifecycle, errors: Errors,
		framingLimits: LineFramer.Limits = .default, decoder: ClaudeProtocolLineDecoder = .init()) {
		transport = .init(lifecycle: lifecycle, inputWriteStrategy: .fileHandle)
		self.errors = errors; self.decoder = decoder; self.framingLimits = framingLimits; framer = .init(limits: framingLimits)
	}
	@discardableResult public func spawn(_ spec: AgentNativeProcessTransport.LaunchSpec) throws -> Int32 {
		let pid = try transport.spawn(spec)
		framer = .init(limits: framingLimits); stderrTail.removeAll(keepingCapacity: false); decodeFailure = nil
		return pid
	}
	public func startReaders(onStdout: @escaping @Sendable (UInt64, Data) async -> Void,
		onStderr: @escaping @Sendable (UInt64, Data) async -> Void, onStdoutEOF: @escaping @Sendable (UInt64) async -> Void) throws {
		try transport.startReaders(stdoutLabel: "Claude stdout", stderrLabel: "Claude stderr",
			onStdout: onStdout, onStderr: onStderr, onStdoutEOF: onStdoutEOF)
	}
	public func invalidate(expectedGeneration: UInt64? = nil) -> AgentNativeProcessTransport.TerminationLease? {
		guard expectedGeneration == nil || expectedGeneration == generation else { return nil }
		let lease = transport.invalidate(expectedGeneration: expectedGeneration)
		framer = .init(limits: framingLimits)
		return lease
	}
	public func writeLine(_ data: Data, onOutbound: (Data) -> Void) throws {
		guard hasProcess else { throw errors.unavailable() }
		let generation = generation
		onOutbound(data)
		var frame = data; frame.append(0x0A)
		do { try transport.writeFrame(frame, expectedGeneration: generation) }
		catch { throw errors.inputWriteFailed(error.localizedDescription) }
	}
	@discardableResult public func consumeStdout(_ data: Data, generation: UInt64, allowPlaintext: () -> Bool, onEvent: (Event) -> Void) -> DecodeFailure? {
		guard current(generation) else { return nil }
		var lines: [Data] = []; var diagnostics: [LineFramer.Diagnostic] = []
		framer.feed(data, onDiagnostic: { diagnostics.append($0) }) { lines.append($0) }
		for diagnostic in diagnostics { guard current(generation) else { return nil }; onEvent(.framing(diagnostic)) }
		return consume(lines, generation: generation, allowPlaintext: allowPlaintext, onEvent: onEvent)
	}
	@discardableResult public func flushStdout(generation: UInt64, allowPlaintext: () -> Bool, onEvent: (Event) -> Void) -> DecodeFailure? {
		guard current(generation) else { return nil }
		var lines: [Data] = []; framer.flush { lines.append($0) }
		return consume(lines, generation: generation, allowPlaintext: allowPlaintext, onEvent: onEvent)
	}
	public func consumeStderr(_ data: Data, generation: UInt64, onEvent: (Event) -> Void) {
		guard generation == self.generation, hasProcess else { return }
		appendTail(&stderrTail, chunk: data, limit: 256 * 1024)
		onEvent(.stderr(data))
	}
	private func current(_ generation: UInt64) -> Bool { generation == self.generation && hasProcess && decodeFailure == nil }
	private func consume(_ lines: [Data], generation: UInt64, allowPlaintext: () -> Bool, onEvent: (Event) -> Void) -> DecodeFailure? {
		for line in lines {
			guard current(generation) else { return nil }
			onEvent(.inboundLine(line)); guard current(generation) else { return nil }
			let allowed = allowPlaintext(); guard current(generation) else { return nil }
			for event in decoder.decode(line, allowPlaintext: allowed) {
				guard current(generation) else { return nil }
				if case .failed(let error, let preview) = event {
					let failure = DecodeFailure(preview: preview, error: error); decodeFailure = failure
					onEvent(.protocolEvent(event))
					return generation == self.generation && hasProcess && decodeFailure != nil ? failure : nil
				}
				onEvent(.protocolEvent(event))
			}
		}
		return nil
	}
}
