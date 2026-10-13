import Foundation
import AgentRuntimeKit
import AgentToolPersistence
import AgentTranscriptExport

/// Caller-owned materialization. Projection is a host value; no app/rendering
/// module enters the service. Every visibility retry sanitizes the original input.
public struct AgentTranscriptMaterializationService<Projection> {
    private let services: AgentTranscriptMaterializationServices<Projection>
    public init(services: AgentTranscriptMaterializationServices<Projection>) { self.services = services }
	private enum MaterializationPurpose {
		case runtimePresentation
		case persistentStorage
	}

	public func runtimeTranscript(_ transcript: AgentTranscript) -> AgentTranscriptMaterializationResult<Projection> {
		materialize(transcript, purpose: .runtimePresentation)
	}

	public func persistedTranscript(
		from transcript: AgentTranscript,
		protectedTurnID: UUID? = nil
	) -> AgentTranscriptMaterializationResult<Projection> {
		let normalized = services.compact(transcript, protectedTurnID)
		return persistedNormalizedTranscript(normalized)
	}

	public func persistedNormalizedTranscript(_ transcript: AgentTranscript) -> AgentTranscriptMaterializationResult<Projection> {
		materialize(
			services.truncateTranscript(transcript),
			purpose: .persistentStorage
		)
	}

	public func handoffTranscript(
		from transcript: AgentTranscript,
		upToRowID: UUID?
	) -> AgentTranscriptMaterializationResult<Projection> {
		let exportTurns = AgentTranscriptExportService.turnsForExport(from: transcript, upToRowID: upToRowID)
		let truncatedTurns = services.truncateExportSlice(exportTurns)
		let exportTranscript = AgentTranscript(
			version: transcript.version,
			turns: truncatedTurns,
			nextSequenceIndex: transcript.nextSequenceIndex,
			compactionFrontier: nil
		)
		return materialize(exportTranscript, purpose: .runtimePresentation)
	}

	private func materialize(
		_ transcript: AgentTranscript,
		purpose: MaterializationPurpose
	) -> AgentTranscriptMaterializationResult<Projection> {
		switch purpose {
		case .runtimePresentation:
			return materializeRuntimeTranscript(transcript)
		case .persistentStorage:
			return materializePersistentStorageTranscript(transcript)
		}
	}

	private func materializeRuntimeTranscript(_ transcript: AgentTranscript) -> AgentTranscriptMaterializationResult<Projection> {
		var visibleToolResultRowIDs = services.visibleToolResultRowIDs(services.project(transcript))
		var finalMetrics = services.sanitizeRuntime(transcript, visibleToolResultRowIDs)
		finalMetrics = .init(
			transcript: services.refreshCaches(finalMetrics.transcript),
			sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
			reusedTurnCount: finalMetrics.reusedTurnCount
		)
		var finalProjection = services.project(finalMetrics.transcript)

		for _ in 0..<3 {
			let stabilizedVisibleToolResultRowIDs = services.visibleToolResultRowIDs(finalProjection)
			guard stabilizedVisibleToolResultRowIDs != visibleToolResultRowIDs else {
				visibleToolResultRowIDs = stabilizedVisibleToolResultRowIDs
				break
			}
			visibleToolResultRowIDs = stabilizedVisibleToolResultRowIDs
			finalMetrics = services.sanitizeRuntime(transcript, visibleToolResultRowIDs)
			finalMetrics = .init(
				transcript: services.refreshCaches(finalMetrics.transcript),
				sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
				reusedTurnCount: finalMetrics.reusedTurnCount
			)
			finalProjection = services.project(finalMetrics.transcript)
		}

		return AgentTranscriptMaterializationResult(
			transcript: finalMetrics.transcript,
			projection: finalProjection,
			visibleToolResultRowIDs: visibleToolResultRowIDs,
			sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
			retainedFullDetailBytes: services.retainedFullDetailBytes(finalMetrics.transcript)
		)
	}

	private func materializePersistentStorageTranscript(_ transcript: AgentTranscript) -> AgentTranscriptMaterializationResult<Projection> {
		var finalMetrics = services.sanitizeStorage(transcript)
		finalMetrics = .init(
			transcript: services.refreshCaches(finalMetrics.transcript),
			sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
			reusedTurnCount: finalMetrics.reusedTurnCount
		)
		let finalProjection = services.project(finalMetrics.transcript)
		let visibleToolResultRowIDs = services.visibleToolResultRowIDs(finalProjection)

		return AgentTranscriptMaterializationResult(
			transcript: finalMetrics.transcript,
			projection: finalProjection,
			visibleToolResultRowIDs: visibleToolResultRowIDs,
			sanitizedActivityCount: finalMetrics.sanitizedActivityCount,
			retainedFullDetailBytes: services.retainedFullDetailBytes(finalMetrics.transcript)
		)
	}
}
