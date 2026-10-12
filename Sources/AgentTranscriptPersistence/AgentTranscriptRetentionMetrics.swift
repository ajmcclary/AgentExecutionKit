import Foundation
import AgentRuntimeKit

public struct AgentTranscriptProtectedTailScanMetrics: Sendable, Equatable {
	public let transcriptTurnCount: Int
	public let limit: Int
	public let turnsVisited: Int
	public let spansInspected: Int
	public let activitiesInspected: Int
	public let alreadyOrderedSpanCount: Int
	public let sortedSpanCount: Int
	public let summarizedToolSignalUseCount: Int
	public let summarizedToolSignalCount: Int
	public let countedToolExecutionCount: Int
	public let protectedTurnCount: Int
	public let durationMS: Double
	public init(transcriptTurnCount: Int, limit: Int, turnsVisited: Int, spansInspected: Int, activitiesInspected: Int, alreadyOrderedSpanCount: Int, sortedSpanCount: Int, summarizedToolSignalUseCount: Int, summarizedToolSignalCount: Int, countedToolExecutionCount: Int, protectedTurnCount: Int, durationMS: Double) {
		self.transcriptTurnCount = transcriptTurnCount
		self.limit = limit
		self.turnsVisited = turnsVisited
		self.spansInspected = spansInspected
		self.activitiesInspected = activitiesInspected
		self.alreadyOrderedSpanCount = alreadyOrderedSpanCount
		self.sortedSpanCount = sortedSpanCount
		self.summarizedToolSignalUseCount = summarizedToolSignalUseCount
		self.summarizedToolSignalCount = summarizedToolSignalCount
		self.countedToolExecutionCount = countedToolExecutionCount
		self.protectedTurnCount = protectedTurnCount
		self.durationMS = durationMS
	}
}


public struct AgentTranscriptCompactionMetrics: Sendable, Equatable {
	public let mode: AgentTranscriptCompactionMode
	public let initialWorkingUnitCount: Int
	public let finalWorkingUnitCount: Int
	public let softGuardSkippedScan: Bool
	public let downshiftIterationCount: Int
	/// Number of archive loop passes. A pass may archive more than one summary turn.
	public let archiveIterationCount: Int
	public let archivedTurnCount: Int
	public let protectedToolTailTurnCount: Int
	public let durationMS: Double
	public init(mode: AgentTranscriptCompactionMode, initialWorkingUnitCount: Int, finalWorkingUnitCount: Int, softGuardSkippedScan: Bool, downshiftIterationCount: Int, archiveIterationCount: Int, archivedTurnCount: Int, protectedToolTailTurnCount: Int, durationMS: Double) {
		self.mode = mode
		self.initialWorkingUnitCount = initialWorkingUnitCount
		self.finalWorkingUnitCount = finalWorkingUnitCount
		self.softGuardSkippedScan = softGuardSkippedScan
		self.downshiftIterationCount = downshiftIterationCount
		self.archiveIterationCount = archiveIterationCount
		self.archivedTurnCount = archivedTurnCount
		self.protectedToolTailTurnCount = protectedToolTailTurnCount
		self.durationMS = durationMS
	}
}


