import Foundation
import AgentRuntimeKit

public struct AgentSanitizedToolResult: Equatable, Sendable {
	public let text: String
	public let resultJSON: String?
	public let toolIsError: Bool?
	public let persistedStatusWord: String
	public let transcriptStatus: AgentTranscriptToolStatus
	public let summaryOnly: Bool
	public let processID: String?
	public let exitCode: Int?
	public let preservesRawPayload: Bool

	public var shouldRetainEphemeralRawPayload: Bool {
		!preservesRawPayload && summaryOnly
	}
    public init(text: String, resultJSON: String?, toolIsError: Bool?, persistedStatusWord: String, transcriptStatus: AgentTranscriptToolStatus, summaryOnly: Bool, processID: String?, exitCode: Int?, preservesRawPayload: Bool) {
        self.text = text
        self.resultJSON = resultJSON
        self.toolIsError = toolIsError
        self.persistedStatusWord = persistedStatusWord
        self.transcriptStatus = transcriptStatus
        self.summaryOnly = summaryOnly
        self.processID = processID
        self.exitCode = exitCode
        self.preservesRawPayload = preservesRawPayload
    }

}

public struct AgentSanitizedTranscriptMetrics: Equatable, Sendable {
	public let transcript: AgentTranscript
	public let sanitizedActivityCount: Int
	public let reusedTurnCount: Int
    public init(transcript: AgentTranscript, sanitizedActivityCount: Int, reusedTurnCount: Int) {
        self.transcript = transcript
        self.sanitizedActivityCount = sanitizedActivityCount
        self.reusedTurnCount = reusedTurnCount
    }

}

public struct AgentPersistedToolResultSummary: Equatable, Sendable {
	public let resultJSON: String
	public let statusWord: String
	public let transcriptStatus: AgentTranscriptToolStatus
	public let toolIsError: Bool?
	public let processID: String?
	public let exitCode: Int?
	public let summaryText: String
	public let summaryOnly: Bool
    public init(resultJSON: String, statusWord: String, transcriptStatus: AgentTranscriptToolStatus, toolIsError: Bool?, processID: String?, exitCode: Int?, summaryText: String, summaryOnly: Bool) {
        self.resultJSON = resultJSON
        self.statusWord = statusWord
        self.transcriptStatus = transcriptStatus
        self.toolIsError = toolIsError
        self.processID = processID
        self.exitCode = exitCode
        self.summaryText = summaryText
        self.summaryOnly = summaryOnly
    }

}

public enum AgentToolResultSanitizationPurpose: Sendable {
	case runtimePresentation
	case persistentStorage
}


/// Host-prepared fallback presentation, containing no tool-card/UI type.
public struct AgentToolStoragePresentation: Sendable {
    public let resultJSON: String
    public let summaryText: String
    public init(resultJSON: String, summaryText: String) {
        self.resultJSON = resultJSON; self.summaryText = summaryText
    }
}
