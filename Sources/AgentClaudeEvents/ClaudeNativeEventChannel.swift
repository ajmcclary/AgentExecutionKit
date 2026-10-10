import Foundation

/// Actor-confined native event-stream lifetime. Hosts keep projection and viewport
/// policy. Tokens optionally fence asynchronous producers from replaced streams.
public final class ClaudeNativeEventChannel {
	public struct Token: Equatable, Sendable { fileprivate let id: UUID }
	public private(set) var token = Token(id: UUID())
	public private(set) var events: AsyncStream<ClaudeNativeEvent>
	private var continuation: AsyncStream<ClaudeNativeEvent>.Continuation?
	public var isOpen: Bool { continuation != nil }
	public init() {
		let pair = AsyncStream<ClaudeNativeEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
	}
	public func ensureReady() { if !isOpen { reset() } }
	public func reset() {
		finish(); token = Token(id: UUID())
		let pair = AsyncStream<ClaudeNativeEvent>.makeStream(); events = pair.stream; continuation = pair.continuation
	}
	public func emit(_ event: ClaudeNativeEvent, for producer: Token? = nil) {
		guard producer == nil || producer == token else { return }
		continuation?.yield(event)
	}
	public func finish() { let old = continuation; continuation = nil; old?.finish() }
	deinit { continuation?.finish() }
}
