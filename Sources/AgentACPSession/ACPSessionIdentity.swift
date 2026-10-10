import Foundation

/// Validated ACP authority, preserving accepted UTF-8 bytes without normalization.
public enum ACPSessionIdentity {
	/// Documented upper bound on a session identity, in UTF-8 bytes. Far above any real
	/// identifier; a value beyond it is corrupt or hostile, not an id.
	public static let maxByteCount = 4096

	/// True when the scalar can forge log structure (line breaks, controls) or visual
	/// identity (bidi/format controls) in a place the identity is logged or displayed.
	public static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
		if scalar.value < 0x20 || scalar.value == 0x7F { return true }
		if (0x80...0x9F).contains(scalar.value) { return true }
		switch scalar.properties.generalCategory {
		case .control, .format, .lineSeparator, .paragraphSeparator:
			return true
		default:
			return false
		}
	}

	/// The exact, byte-identical identity when valid; nil when it must never become
	/// authority. Never trims — the returned value is the input verbatim.
	public static func validated(_ raw: String?) -> String? {
		guard let raw, !raw.isEmpty else { return nil }
		guard raw.utf8.count <= maxByteCount else { return nil }
		guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
		guard !raw.unicodeScalars.contains(where: isForbiddenScalar) else { return nil }
		return raw
	}
}
