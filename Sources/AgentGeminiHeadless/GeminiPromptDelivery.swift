import Foundation

public enum GeminiPromptDelivery {
	/// Escapes every `@` (as `[at]`) so the Gemini CLI does not expand it as an
	/// @-command or file reference, except where it introduces one of the exact
	/// `references` the host attached. Path-shaped text the host did not attach
	/// (`@/…`, `@~/…`, `@./…`, `@{…}`, `@C:…` pasted or quoted in the prompt) is
	/// escaped too: the CLI would otherwise read that file and send it.
	///
	/// A reference is preserved only when the text after `@` is the reference
	/// itself, followed by the end of the text or by whitespace or one of
	/// `,;:)]}>"'` (so `@/a.png` does not also preserve `@/a.png.bak`).
	public static func escapeSpecialCharacters(in text: String, preservingReferences references: Set<String> = []) -> String {
		let candidates = references.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
		var result = ""
		var index = text.startIndex
		while index < text.endIndex {
			let character = text[index]
			guard character == "@" else {
				result.append(character)
				index = text.index(after: index)
				continue
			}
			let afterAt = text.index(after: index)
			if let reference = candidates.first(where: { isReference($0, in: text, at: afterAt) }) {
				result.append("@")
				result.append(reference)
				index = text.index(afterAt, offsetBy: reference.count)
			} else {
				result.append("[at]")
				index = afterAt
			}
		}
		return result
	}

	private static func isReference(_ reference: String, in text: String, at start: String.Index) -> Bool {
		guard text[start...].hasPrefix(reference) else { return false }
		let end = text.index(start, offsetBy: reference.count)
		guard end < text.endIndex else { return true }
		let next = text[end]
		return next.isWhitespace || ",;:)]}>\"'".contains(next)
	}

	/// Both channels go through the same escaping; only the host's declared
	/// attachment paths survive as `@` references.
	public static func combinedInput(systemPrompt: String, userMessage: String, attachmentPaths: Set<String> = []) -> String {
		"\(escapeSpecialCharacters(in: systemPrompt, preservingReferences: attachmentPaths))\n\n\(escapeSpecialCharacters(in: userMessage, preservingReferences: attachmentPaths))"
	}
}
