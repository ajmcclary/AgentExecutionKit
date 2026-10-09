import Foundation

/// Immutable JSON storage preserves numeric precision and future fields without
/// exposing an SDK object or sharing a Foundation reference graph across tasks.
public struct ClaudeProtocolJSONObject: Sendable, Equatable {
	public let data: Data
	public init(data: Data) throws {
		guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
			throw ClaudeNativeProtocolCodec.CodecError.invalidJSON
		}
		self.data = data
	}
	fileprivate init(object: [String: Any]) throws {
		data = try JSONSerialization.data(withJSONObject: object)
	}
	/// A fresh compatibility view for host protocol adapters.
	public func dictionary() throws -> sending [String: Any] {
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw ClaudeNativeProtocolCodec.CodecError.invalidJSON
		}
		return object
	}
}

public enum ClaudeNativeProtocolCodec {
	public enum InboundMessage: Sendable {
		case streamPayload(ClaudeProtocolJSONObject)
		case controlRequest(ControlRequest)
		case controlResponse(ControlResponse)
		case controlCancelRequest(requestID: String)
		case keepAlive
	}
	public struct ControlRequest: Sendable {
		public let requestID: String
		public let request: ClaudeProtocolJSONObject
		public let subtype: String
	}
	public struct ControlResponse: Sendable {
		public let requestID: String
		public let subtype: String
		public let response: ClaudeProtocolJSONObject?
		public let error: String?
		public let pendingPermissionRequests: [ClaudeProtocolJSONObject]
	}
	public enum CodecError: Error, Equatable, Sendable {
		case invalidJSON
		case unsupportedPayload
	}

	public static func decodeLine(_ data: Data) throws -> InboundMessage? {
		let raw: ClaudeRawProtocolCodec.InboundMessage?
		do { raw = try ClaudeRawProtocolCodec.decodeLine(data) }
		catch let error as ClaudeRawProtocolCodec.CodecError {
			switch error {
			case .invalidJSON: throw CodecError.invalidJSON
			case .unsupportedPayload: throw CodecError.unsupportedPayload
			}
		}
		guard let raw else { return nil }
		switch raw {
		case .streamPayload(let payload): return .streamPayload(try .init(object: payload))
		case .controlRequest(let value):
			return .controlRequest(.init(requestID: value.requestID, request: try .init(object: value.request), subtype: value.subtype))
		case .controlResponse(let value):
			return .controlResponse(.init(requestID: value.requestID, subtype: value.subtype,
				response: try value.response.map { try .init(object: $0) }, error: value.error,
				pendingPermissionRequests: try value.pendingPermissionRequests.map { try .init(object: $0) }))
		case .controlCancelRequest(let id): return .controlCancelRequest(requestID: id)
		case .keepAlive: return .keepAlive
		}
	}

	public static func encodeControlRequest(requestID: String, request: ClaudeProtocolJSONObject) throws -> Data {
		try ClaudeRawProtocolCodec.encodeControlRequest(requestID: requestID, request: request.dictionary())
	}
	public static func encodeControlResponseSuccess(requestID: String, response: ClaudeProtocolJSONObject? = nil) throws -> Data {
		try ClaudeRawProtocolCodec.encodeControlResponseSuccess(requestID: requestID, response: response?.dictionary())
	}
	public static func encodeControlResponseError(requestID: String, error: String) throws -> Data {
		try ClaudeRawProtocolCodec.encodeControlResponseError(requestID: requestID, error: error)
	}
	public static func encodeUserMessage(text: String, sessionID: String?) throws -> Data {
		try ClaudeRawProtocolCodec.encodeUserMessage(text: text, sessionID: sessionID)
	}
}
