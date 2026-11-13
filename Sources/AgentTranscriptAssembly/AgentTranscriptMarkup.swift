import Foundation

/// Escaping shared by the XML-like transcript renderers (`forkXML`,
/// `conversationHistory`). Bodies keep the historical unescaped format except
/// that they can never open or close one of the transcript's structural tags,
/// nor the wrappers hosts put around a rendered history; the next model treats
/// those as turn structure and authority.
public enum AgentTranscriptMarkup {
	/// Tag names a body must not be able to open or close (case-insensitive).
	public static let structuralTagNames: [String] = [
		"transcript", "user", "assistant", "system", "error", "tool_call", "tool_result", "note",
		"previous_conversation", "current_instruction",
	]

	private static let structuralTagPattern = try! NSRegularExpression(
		pattern: "<(/?)(" + structuralTagNames.joined(separator: "|") + #")(?=[\s/>])"#,
		options: [.caseInsensitive])

	/// Leaves body text unescaped except where it would open or close a
	/// structural tag; there the `<` becomes `&lt;`.
	public static func neutralizedBody(_ text: String) -> String {
		guard text.contains("<") else { return text }
		let range = NSRange(text.startIndex..<text.endIndex, in: text)
		return structuralTagPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "&lt;$1$2")
	}

	/// Escapes a value placed inside a double-quoted attribute.
	public static func escapedAttribute(_ value: String) -> String {
		value.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
	}
}
