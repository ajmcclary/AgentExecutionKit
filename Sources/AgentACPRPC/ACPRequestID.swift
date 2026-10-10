import Foundation
import OpenCodeRuntimeKit

/// Typed wire identity. Permission ownership uses storageKey; only response correlation
/// may use compatibleResponseKeys for canonical numeric echoes.
public enum ACPRequestID: Hashable, Sendable {
	case string(String)
	case int(Int)
	case double(Double)

	public var storageKey: String {
		switch self {
		case .string(let value):
			return "s:\(value)"
		case .int(let value):
			return "i:\(value)"
		case .double(let value):
			return "d:\(value)"
		}
	}

	public var displayValue: String {
		switch self {
		case .string(let value):
			return value
		case .int(let value):
			return String(value)
		case .double(let value):
			return String(value)
		}
	}

	public var jsonValue: Any {
		switch self {
		case .string(let value):
			return value
		case .int(let value):
			return value
		case .double(let value):
			return value
		}
	}
	/// Decode without allowing Foundation boolean-to-integer bridging.
	public static func decode(_ rawValue: Any?) -> ACPRequestID? {
		if let rawValue, OpenCodeJSONNumberPolicy.isJSONBoolean(rawValue) { return nil }
		switch rawValue {
		case let value as String:
			return .string(value)
		case let value as Int:
			return .int(value)
		case let value as NSNumber:
			let doubleValue = value.doubleValue
			// `intValue` CLAMPS an out-of-range double rather than trapping, which would
			// silently collapse two distinct ids onto `Int.max`. Only an exactly
			// representable integer becomes `.int`.
			if let exact = Self.exactIntAlias(from: doubleValue) {
				return .int(exact)
			}
			guard doubleValue.isFinite else { return nil }
			return .double(doubleValue)
		case let value as Double:
			return .double(value)
		default:
			return nil
		}
	}

	private static func exactIntAlias(from value: Double) -> Int? {
		OpenCodeJSONNumberPolicy.exactInteger(fromFinite: value)
	}

	private static func canonicalNumericAlias(fromString value: String) -> Int? {
		guard let parsed = OpenCodeJSONNumberPolicy.canonicalDecimalInteger(value) else { return nil }
		guard Self.isWithinSafeIntegerRange(parsed) else { return nil }
		return parsed
	}

	/// Compare bounds directly: abs(Int.min) overflows.
	private static func isWithinSafeIntegerRange(_ value: Int) -> Bool {
		value >= -OpenCodeJSONNumberPolicy.maxSafeIntegerInDouble
			&& value <= OpenCodeJSONNumberPolicy.maxSafeIntegerInDouble
	}

	public var compatibleResponseKeys: [String] {
		let id = self
		var keys = [id.storageKey]
		switch id {
		case .string(let value):
			if let alias = Self.canonicalNumericAlias(fromString: value) {
				keys.append(ACPRequestID.int(alias).storageKey)
				keys.append(ACPRequestID.double(Double(alias)).storageKey)
			}
		case .int(let value):
			guard Self.isWithinSafeIntegerRange(value) else { break }
			keys.append(ACPRequestID.string(String(value)).storageKey)
			keys.append(ACPRequestID.double(Double(value)).storageKey)
		case .double(let value):
			guard let alias = Self.exactIntAlias(from: value) else { break }
			keys.append(ACPRequestID.int(alias).storageKey)
			keys.append(ACPRequestID.string(String(alias)).storageKey)
		}
		var seen = Set<String>()
		return keys.filter { seen.insert($0).inserted }
	}
}
