import Foundation

public enum CodexExecFailureClassifier {
	public static func extractBrokenServerName(from stderr: String) -> String? {
		let nsString = stderr as NSString
		let range = NSRange(location: 0, length: nsString.length)

		// First try to match MCP client startup failures (e.g., timeout, connection errors)
		// - "MCP client for `ServerName` failed to start: request timed out"
		// - "MCP client for `ServerName` failed to start"
		let mcpFailurePattern = #"MCP client for [`'"]?([^`'"]+)[`'"]? failed to start"#
		if let mcpFailureRegex = try? NSRegularExpression(pattern: mcpFailurePattern, options: [.caseInsensitive]),
		   let match = mcpFailureRegex.firstMatch(in: stderr, range: range),
		   match.numberOfRanges >= 2 {
			let serverNameRange = match.range(at: 1)
			if serverNameRange.location != NSNotFound {
				return nsString.substring(with: serverNameRange)
			}
		}

		// Fall back to invalid transport pattern:
		// - "Error: invalid transport\nin `mcp_servers.ServerName`"
		// - "Error: invalid transport in 'mcp_servers.ServerName'"
		// - "Error: invalid transport in \"mcp_servers.Server Name\""
		// - "Error: invalid transport in mcp_servers.ServerName"
		let transportPattern = #"invalid transport(?:\s+in)?[\s\S]*?['"`]?mcp_servers\.([^'"`\r\n]+)"#
		guard let transportRegex = try? NSRegularExpression(pattern: transportPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
			return nil
		}

		guard let match = transportRegex.firstMatch(in: stderr, range: range), match.numberOfRanges >= 2 else {
			return nil
		}

		let serverNameRange = match.range(at: 1)
		guard serverNameRange.location != NSNotFound else { return nil }

		return nsString.substring(with: serverNameRange)
	}

	/// Whether an error detail indicates the requested MODEL does not exist.
	/// Catalog-neutral (no model-name assumptions). Rate limits,
	/// authentication failures, transport errors, and malformed responses do
	/// not match — those must never trigger model substitution or advisories.
	public static func isModelUnavailableErrorDetail(_ errorDetail: String) -> Bool {
		let lowered = errorDetail.lowercased()
		return lowered.contains("model_not_found")
			|| (lowered.contains("requested model") && lowered.contains("does not exist"))
			|| (lowered.contains("404") && lowered.contains("model"))
	}

}
