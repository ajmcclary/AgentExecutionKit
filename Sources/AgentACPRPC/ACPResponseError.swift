import Foundation
import OpenCodeRuntimeKit

/// ACP error projection preserving nested detail, bounded JSON previews, and exact codes.
public enum ACPResponseError {
	public static func message(from error: [String: Any]) -> String {
		let message = trimmedNonEmptyString(error["message"])
		let data = error["data"]
		let detail = responseErrorDetail(from: data)
		let base = message ?? "Unknown ACP error"
		guard let detail, !detail.isEmpty, detail != base else { return base }
		return "\(base): \(detail)"
	}

	private static func responseErrorDetail(from data: Any?) -> String? {
		guard let data else { return nil }
		if let text = trimmedNonEmptyString(data) {
			return text
		}
		if let dictionary = data as? [String: Any] {
			for path in [["message"], ["error", "message"], ["details"], ["cause", "message"]] {
				if let text = nestedTrimmedString(in: dictionary, path: path) {
					return text
				}
			}
			return compactJSONPreview(data)
		}
		if let array = data as? [Any] {
			return compactJSONPreview(array)
		}
		return nil
	}

	private static func nestedTrimmedString(in dictionary: [String: Any], path: [String]) -> String? {
		var value: Any? = dictionary
		for key in path {
			guard let nested = value as? [String: Any] else { return nil }
			value = nested[key]
		}
		return trimmedNonEmptyString(value)
	}

	private static func trimmedNonEmptyString(_ value: Any?) -> String? {
		guard let string = value as? String else { return nil }
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static func compactJSONPreview(_ value: Any, limit: Int = 2_000) -> String? {
		guard JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
			let string = String(data: data, encoding: .utf8),
			!string.isEmpty else {
			return nil
		}
		guard string.count > limit else { return string }
		return String(string.prefix(limit)) + "…"
	}

	/// A JSON-RPC error code is a provider-supplied number too: `intValue` clamped an
	/// out-of-range value onto `Int.max`, which would silently impersonate a real code.
	public static func code(from error: [String: Any]) -> Int? {
		OpenCodeJSONNumberPolicy.exactInteger(error["code"])
	}

}
