import Foundation
import AgentRuntimeKit

public enum AgentTranscriptExecutionMetadata {
public static func merged(
	_ preferred: AgentTranscriptToolExecution,
	with fallback: AgentTranscriptToolExecution
) -> AgentTranscriptToolExecution {
	var merged = preferred
	if merged.toolName == nil {
		merged.toolName = fallback.toolName
	}
	if merged.invocationID == nil {
		merged.invocationID = fallback.invocationID
	}
	if merged.argsJSON == nil {
		merged.argsJSON = fallback.argsJSON
	}
	if merged.resultJSON == nil {
		merged.resultJSON = fallback.resultJSON
	}
	if merged.toolIsError == nil {
		merged.toolIsError = fallback.toolIsError
	}
	if merged.processID == nil {
		merged.processID = fallback.processID
	}
	if merged.exitCode == nil {
		merged.exitCode = fallback.exitCode
	}
	if merged.summaryText?.isEmpty ?? true {
		merged.summaryText = fallback.summaryText
	}
	let mergedKeyPaths = Array(NSOrderedSet(array: fallback.keyPaths + merged.keyPaths)) as? [String]
		?? (fallback.keyPaths + merged.keyPaths)
	merged.keyPaths = mergedKeyPaths
	merged.summaryOnly = merged.summaryOnly || fallback.summaryOnly
	return merged
}
}
