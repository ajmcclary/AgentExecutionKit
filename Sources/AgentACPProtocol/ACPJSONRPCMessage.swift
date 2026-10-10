import Foundation
import AgentACPRPC

/// Immutable JSON object. Dictionary access creates a fresh host-owned graph.
public struct ACPJSONObject: Sendable, Equatable {
	public let data: Data
	public enum DecodeError: Error { case expectedObject }
	public init(data: Data) throws {
		guard try JSONSerialization.jsonObject(with: data) is [String: Any] else { throw DecodeError.expectedObject }
		self.data = data
	}
	public init(object: [String: Any]) throws {
		self.data = try JSONSerialization.data(withJSONObject: object)
	}
	public func dictionary() throws -> [String: Any] {
		guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.expectedObject }
		return object
	}
	public static let empty = try! ACPJSONObject(data: Data("{}".utf8))
}

/// Wire classification preserves ACP's existing tolerance of absent version fields,
/// unknown envelopes, missing/non-object params, and result-before-error precedence.
public struct ACPJSONRPCMessage: Sendable {
	public enum Kind: Sendable { case request, response, notification, unknown }
	public enum Response: Sendable {
		case result(ACPJSONObject)
		case failure(message: String, code: Int?)
		case missing
	}
	public let payload: ACPJSONObject
	public let id: ACPRequestID?
	public let method: String?
	public let params: ACPJSONObject
	public let kind: Kind
	public let response: Response?
	public init(data: Data) throws {
		payload = try ACPJSONObject(data: data)
		let object = try payload.dictionary()
		id = ACPRequestID.decode(object["id"])
		method = object["method"] as? String
		params = try (object["params"] as? [String: Any]).map { try ACPJSONObject(object: $0) } ?? .empty
		if id != nil, method != nil { kind = .request; response = nil }
		else if id != nil {
			kind = .response
			if let result = object["result"] as? [String: Any] { response = .result(try .init(object: result)) }
			else if let error = object["error"] as? [String: Any] {
				response = .failure(message: ACPResponseError.message(from: error), code: ACPResponseError.code(from: error))
			} else { response = .missing }
		} else { kind = method == nil ? .unknown : .notification; response = nil }
	}
	public static func request(id: ACPRequestID, method: String, params: ACPJSONObject) throws -> ACPJSONObject {
		try .init(object: ["jsonrpc": "2.0", "id": id.jsonValue, "method": method, "params": params.dictionary()])
	}
}
