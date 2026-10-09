import Foundation

public enum GeminiPromptDelivery {
	public static func escapeSpecialCharacters(in text: String) -> String {
		// Escape stray @ characters to avoid accidental @-command expansion,
		// but preserve explicit file references (for image/file attachments).
		var result = ""
		var index = text.startIndex
		while index < text.endIndex {
			let character = text[index]
			guard character == "@" else {
				result.append(character)
				index = text.index(after: index)
				continue
			}

			let nextIndex = text.index(after: index)
			let nextCharacter: Character? = nextIndex < text.endIndex ? text[nextIndex] : nil
			if shouldPreserveAtReference(in: text, at: index, nextCharacter: nextCharacter) {
				result.append(character)
			} else {
				result.append("[at]")
			}
			index = text.index(after: index)
		}
		return result
	}

	private static func shouldPreserveAtReference(
		in text: String,
		at atIndex: String.Index,
		nextCharacter: Character?
	) -> Bool {
		guard let nextCharacter else { return false }
		if nextCharacter == "/" || nextCharacter == "~" || nextCharacter == "{" {
			return true
		}
		if nextCharacter == "." {
			let dotIndex = text.index(after: atIndex)
			let afterDotIndex = text.index(after: dotIndex)
			if afterDotIndex < text.endIndex, text[afterDotIndex] == "/" {
				return true // @./path
			}
			if afterDotIndex < text.endIndex,
			   text[afterDotIndex] == "." {
				let afterDoubleDotIndex = text.index(after: afterDotIndex)
				if afterDoubleDotIndex < text.endIndex,
				   text[afterDoubleDotIndex] == "/" {
					return true // @../path
				}
			}
		}
		// Preserve Windows-style absolute paths like @C:\foo or @C:/foo
		if nextCharacter.isLetter {
			let driveLetterIndex = text.index(after: atIndex)
			let colonIndex = text.index(after: driveLetterIndex)
			if colonIndex < text.endIndex,
			   text[colonIndex] == ":" {
				return true // @C:\path or @C:/path
			}
		}
		return false
	}

	public static func combinedInput(systemPrompt: String, userMessage: String) -> String {
		"\(systemPrompt)\n\n\(escapeSpecialCharacters(in: userMessage))"
	}
}
