import Foundation

public enum ClaudePromptDelivery {
	public static let instructionsTag = "claude_code_instructions"

	public static func decoratedUserMessage(_ userMessage: String, instructions: String) -> String {
		let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInstructions.isEmpty else {
			return userMessage
		}

		let instructionsBlock = """
		<\(instructionsTag)>
		\(trimmedInstructions)
		</\(instructionsTag)>
		"""

		let trimmedUserMessage = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedUserMessage.isEmpty else {
			return instructionsBlock
		}

		return """
		\(instructionsBlock)

		\(userMessage)
		"""
	}
}
