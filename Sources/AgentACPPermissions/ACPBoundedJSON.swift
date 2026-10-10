import Foundation

/// Bounded, escape-aware provider input projection.
public enum ACPBoundedJSON {
	public static func serialized(_ value: Any?, byteLimit: Int) -> String? {
		guard let value, !(value is NSNull) else { return nil }
		let overLimitMarker = "[omitted: rawInput exceeds \(byteLimit) bytes]"
		// The estimate must follow the ACTUAL serialization branch (thirteenth round,
		// finding 7). `serializeJSON` returns a TOP-LEVEL String verbatim (no quotes, no
		// escaping), but `estimatedJSONByteSize` models every String as a quoted, escaped
		// JSON string — so a quote-heavy top-level String whose emitted UTF-8 is under the
		// limit was rejected as oversized. A top-level String is therefore estimated by its
		// raw UTF-8 length; nested strings (inside a dict/array) still go through the
		// escape-aware estimate, matching `JSONSerialization`'s escaping for those.
		let estimate = (value as? String)?.utf8.count
			?? Self.estimatedJSONByteSize(value, limit: byteLimit)
		guard estimate <= byteLimit else {
			return overLimitMarker
		}
		guard let serialized = serializeJSON(value) else { return nil }
		// Authoritative check on what would actually be emitted. Bounded work: anything
		// reaching here has a compact escaped size ≤ byteLimit, so serialization cost is
		// already capped; pretty-printing can push the REAL size past the bound, and
		// nothing over the documented limit may leave this boundary.
		guard serialized.utf8.count <= byteLimit else {
			return overLimitMarker
		}
		return serialized
	}

	/// Bounded, short-circuiting, ESCAPE-AWARE UTF-8 size estimate for a Foundation JSON
	/// value, modeling the compact `JSONSerialization` encoding. Returns as soon as the
	/// running total passes `limit`, so it never walks a huge structure to completion.
	/// Per-scalar costs are upper bounds of the compact encoding (quotes, backslashes and
	/// slashes escape to 2 bytes; C0 controls to at most `\uXXXX` = 6 bytes; everything
	/// else is its raw UTF-8 length), and structural punctuation is counted generously.
	/// The estimate deliberately does NOT model pretty-printed whitespace — the
	/// authoritative post-serialization check in `boundedSerializedJSON` owns exactness.
	public static func estimatedJSONByteSize(_ value: Any, limit: Int) -> Int {
		var total = 0
		func escapedStringCost(_ string: String) {
			total += 2 // surrounding quotes
			for scalar in string.unicodeScalars {
				switch scalar.value {
				case 0x22, 0x5C, 0x2F: // " \ / — serialized as two-byte escapes
					total += 2
				case ..<0x20: // C0 controls — worst case \uXXXX
					total += 6
				default:
					total += UTF8.width(scalar)
				}
				if total > limit { return }
			}
		}
		func walk(_ value: Any) {
			if total > limit { return }
			switch value {
			case let string as String:
				escapedStringCost(string)
			case let array as [Any]:
				total += 2
				for element in array {
					total += 1
					if total > limit { return }
					walk(element)
				}
			case let object as [String: Any]:
				total += 2
				for (key, element) in object {
					total += 4
					escapedStringCost(key)
					if total > limit { return }
					walk(element)
				}
			default:
				total += 24 // numbers, booleans, null — small, fixed proxy
			}
		}
		walk(value)
		return total
	}

	public static func serializeJSON(_ value: Any?) -> String? {
		guard let value else { return nil }
		if let string = value as? String {
			return string
		}
		guard JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
			let string = String(data: data, encoding: .utf8) else {
			return nil
		}
		return string
	}

}
