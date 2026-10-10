import Foundation
import AgentACPRPC
import AgentACPProtocol
import AgentNativeProcessTransport
import ProcessStreamFraming

/// Synchronous connection engine confined to one serialized owner. Reader/waiter
/// callbacks deliver captured generations to that owner; it feeds bytes back here.
/// This preserves actor-ordered protocol dispatch without introducing extra hops.
public final class ACPConnection {
	public struct Errors: Sendable {
		public let unavailable: @Sendable () -> any Error
		public let closed: @Sendable () -> any Error
		public let protocolViolation: @Sendable (String) -> any Error
		public let requestFailed: @Sendable (String, Int?) -> any Error
		public init(unavailable: @escaping @Sendable () -> any Error,
			closed: @escaping @Sendable () -> any Error,
			protocolViolation: @escaping @Sendable (String) -> any Error,
			requestFailed: @escaping @Sendable (String, Int?) -> any Error) {
			self.unavailable = unavailable; self.closed = closed
			self.protocolViolation = protocolViolation; self.requestFailed = requestFailed
		}
	}
	public enum Event: Sendable {
		case inboundLine(String)
		case message(ACPJSONRPCMessage)
		case invalidJSON(preview: String, payloadByteCount: Int)
		case framingFailure(String)
		case stderrLine(String)
		case requestFailed(method: String, message: String, code: Int?)
		case unmatchedResponse(id: ACPRequestID, rawLine: String)
	}
	public struct Diagnostics: Sendable, Equatable {
		public fileprivate(set) var stdoutByteCount = 0
		public fileprivate(set) var stdoutLineCount = 0
		public fileprivate(set) var invalidACPLineCount = 0
		public fileprivate(set) var stderrLineCount = 0
		public fileprivate(set) var lastStdoutPreview: String?
		public fileprivate(set) var lastInvalidACPLinePreview: String?
		public fileprivate(set) var lastStderrPreview: String?
	}
	private let transport: AgentNativeProcessTransport
	private let requests: ACPRequestStore
	private let errors: Errors
	private let limits: ACPStdoutDecoder.Limits?
	private var stdout = ACPStdoutDecoder()
	private var stderr = LineFramer()
	public private(set) var diagnostics = Diagnostics()
	public var generation: UInt64 { transport.generation }
	public var hasProcess: Bool { transport.hasProcess }
	public var hasWaiter: Bool { transport.hasWaiter }
	public var pid: Int32? { transport.pid }
	public var pendingMethods: [String] { requests.pendingMethods }
	public var stdoutFramingFailed: Bool { stdout.failed }

	public init(lifecycle: AgentNativeProcessTransport.Lifecycle, errors: Errors,
		limits: ACPStdoutDecoder.Limits? = nil, sleep: @escaping ACPRequestStore.Sleep = { try await Task.sleep(for: $0) }) {
		transport = .init(lifecycle: lifecycle)
		requests = .init(sleep: sleep)
		self.errors = errors; self.limits = limits
		stdout = .init(limits: limits)
	}
	@discardableResult
	public func spawn(_ spec: AgentNativeProcessTransport.LaunchSpec) throws -> Int32 {
		let pid = try transport.spawn(spec)
		requests.failAll(with: errors.closed())
		stdout = .init(limits: limits); stderr = .init(); diagnostics = .init()
		return pid
	}
	public func startReaders(onStdout: @escaping @Sendable (UInt64, Data) async -> Void,
		onStderr: @escaping @Sendable (UInt64, Data) async -> Void) throws {
		try transport.startReaders(stdoutLabel: "ACP stdout", stderrLabel: "ACP stderr", onStdout: onStdout, onStderr: onStderr)
	}
	public func startWaiter(onExit: @escaping @Sendable (UInt64, Int32, Bool) async -> Void) throws {
		try transport.startWaiter(onExit: onExit)
	}
	@discardableResult
	public func observeExit(expectedGeneration: UInt64) -> Bool {
		guard transport.observeExit(expectedGeneration: expectedGeneration) else { return false }
		requests.failAll(with: errors.closed())
		return true
	}
	public func invalidate(expectedGeneration: UInt64? = nil) -> AgentNativeProcessTransport.TerminationLease? {
		guard expectedGeneration == nil || expectedGeneration == generation else { return nil }
		requests.failAll(with: errors.closed())
		return transport.invalidate(expectedGeneration: expectedGeneration)
	}
	public func failRequests(with error: any Error) { requests.failAll(with: error) }
	@discardableResult
	public func expire(_ ticket: ACPRequestStore.Ticket, makeError: () -> any Error) -> Bool {
		requests.expire(ticket, makeError: makeError)
	}

	/// Registration and wire-write are one synchronous operation. Every failure resolves
	/// the continuation through the same store, including serialization/write failure.
	public func sendRequest(method: String, params: ACPJSONObject,
		continuation: CheckedContinuation<Data, any Error>, deadline: ACPRequestStore.Deadline? = nil,
		onOutbound: (ACPJSONObject) -> Void) {
		guard hasProcess else { continuation.resume(throwing: errors.unavailable()); return }
		let ticket: ACPRequestStore.Ticket
		do { ticket = try requests.register(method: method, continuation: continuation, deadline: deadline) }
		catch { continuation.resume(throwing: error); return }
		do {
			let payload = try ACPJSONRPCMessage.request(id: ticket.id, method: method, params: params)
			try send(payload, onOutbound: onOutbound)
		} catch { requests.cancel(ticket, error: error) }
	}
	public func send(_ payload: ACPJSONObject, onOutbound: (ACPJSONObject) -> Void) throws {
		guard hasProcess else { throw errors.unavailable() }
		let generation = self.generation
		var frame = payload.data; frame.append(0x0A)
		onOutbound(payload)
		try transport.writeFrame(frame, expectedGeneration: generation)
	}

	public func consumeStdout(_ data: Data, generation: UInt64, onEvent: (Event) -> Void) {
		guard generation == self.generation, hasProcess, !stdout.failed else { return }
		diagnostics.stdoutByteCount += data.count
		for event in stdout.feed(data) {
			guard generation == self.generation, hasProcess else { return }
			switch event {
			case .failure(let reason):
				diagnostics.invalidACPLineCount += 1
				onEvent(.framingFailure(reason))
				if generation == self.generation, hasProcess { requests.failAll(with: errors.protocolViolation(reason)) }
			case .line(let line):
				let rawLine = String(data: line, encoding: .utf8) ?? "<non-utf8>"
				diagnostics.stdoutLineCount += 1
				diagnostics.lastStdoutPreview = Self.preview(rawLine)
				onEvent(.inboundLine(rawLine))
				guard generation == self.generation, hasProcess else { return }
				let message: ACPJSONRPCMessage
				do { message = try .init(data: line) }
				catch {
					let preview = String(data: line.prefix(300), encoding: .utf8) ?? "<non-utf8>"
					diagnostics.invalidACPLineCount += 1
					diagnostics.lastInvalidACPLinePreview = Self.preview(preview)
					onEvent(.invalidJSON(preview: preview, payloadByteCount: line.count))
					if generation == self.generation, hasProcess { requests.failAll(with: errors.protocolViolation("Invalid ACP JSON line: \(preview)")) }
					continue
				}
				onEvent(.message(message))
				guard generation == self.generation, hasProcess else { return }
				guard case .response = message.kind, let id = message.id, let response = message.response else { continue }
				let outcome: Result<Data, any Error>
				var failure: (String, Int?)?
				switch response {
				case .result(let object): outcome = .success(object.data)
				case .failure(let message, let code): failure = (message, code); outcome = .failure(errors.requestFailed(message, code))
				case .missing: outcome = .failure(errors.protocolViolation("Missing result/error for request \(id.displayValue)"))
				}
				if let resolved = requests.resolve(responseID: id, with: outcome) {
					if let failure { onEvent(.requestFailed(method: resolved.method, message: failure.0, code: failure.1)) }
				} else {
					onEvent(.unmatchedResponse(id: id, rawLine: rawLine))
					if generation == self.generation, hasProcess { requests.failAll(with: errors.protocolViolation("Received unmatched ACP response id \(id.displayValue).")) }
				}
			}
		}
	}
	public func consumeStderr(_ data: Data, generation: UInt64, onEvent: (Event) -> Void) {
		guard generation == self.generation, hasProcess else { return }
		var lines: [Data] = []
		stderr.feed(data) { lines.append($0) }
		for line in lines {
			guard generation == self.generation, hasProcess else { return }
			guard let trimmed = trimmedASCIIWhitespace(line), let text = String(data: trimmed, encoding: .utf8), !text.isEmpty else { continue }
			diagnostics.stderrLineCount += 1
			diagnostics.lastStderrPreview = Self.preview(text)
			onEvent(.stderrLine(text))
		}
	}
	deinit { requests.failAll(with: errors.closed()) }

	private static func preview(_ text: String) -> String {
		text.count > 240 ? String(text.prefix(240)) + "…" : text
	}
}
