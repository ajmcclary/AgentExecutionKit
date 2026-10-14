import Foundation
import AgentRuntimeKit

/// Owns selection, prioritized loading and streaming. Storage/record policy is
/// host-supplied, and async work inherits the caller actor's isolation.
public struct AgentSessionSidebarService<Record: Sendable>: Sendable {
    private let services: AgentSessionSidebarServices<Record>
    public init(services: AgentSessionSidebarServices<Record>) { self.services = services }
	public func buildSidebarIndexStream(
		_ request: AgentSessionSidebarQuery,
		batchSize: Int = 8,
        isolation: isolated (any Actor)? = #isolation
	) -> AsyncThrowingStream<AgentSessionSidebarBuildBatch, Error> {
		AsyncThrowingStream { continuation in
			let service = self
			let effectiveBatchSize = max(batchSize, 1)
			let task = Task {
                // Referencing the isolated parameter preserves the producer's
                // inherited executor through the stream-builder closure.
                _ = isolation
				#if DEBUG
				let streamStartMS = services.timestampMSIfEnabled()
				var yieldedBatchCount = 0
				var yieldedEntryCount = 0
				var preferredEntriesYielded = 0
				var nonPreferredEntriesYielded = 0
				var prioritizedYielded = false
				var yieldDurationMS: Double = 0
				func logYieldComplete() {
					services.observe(
						"agentSessionIndex.streamYieldComplete",
						[

							"batches": "\(yieldedBatchCount)",
							"entriesYielded": "\(yieldedEntryCount)",
							"preferredEntriesYielded": "\(preferredEntriesYielded)",
							"nonPreferredEntriesYielded": "\(nonPreferredEntriesYielded)",
							"prioritizedYielded": "\(prioritizedYielded)",
							"yieldDuration": services.formatMS(yieldDurationMS),
							"total": streamStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured"
						]
					)
				}
				#endif
				do {
					#if DEBUG
					let metadataStartMS = services.timestampMSIfEnabled()
					#endif
					let records = try await service.services.loadRecords()
					#if DEBUG
					services.observe(
						"agentSessionIndex.streamMetadataFetched",
						[

							"records": "\(records.count)",
							"duration": metadataStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured",
							"batchSize": "\(effectiveBatchSize)",
							"hasPrioritizedTab": "\(request.prioritizedTabID != nil)"
						]
					)
					#endif
					try Task.checkCancellation()
					#if DEBUG
					let projectionStartMS = services.timestampMSIfEnabled()
					#endif
					let projection = projectSidebarIndex(records: records, request: request)
					#if DEBUG
					services.observe(
						"agentSessionIndex.streamProjected",
						[

							"entries": "\(projection.entriesBySessionID.count)",
							"preferredTabs": "\(projection.preferredEntryByTabID.count)",
							"orderedPreferred": "\(projection.orderedPreferredEntries.count)",
							"duration": projectionStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured"
						]
					)
					#endif
					var emittedSessionIDs: Set<UUID> = []

					func yieldBatch(entries: [AgentSessionIndexEntry]) {
						guard !entries.isEmpty else { return }
						var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
						var preferredSessionIDByTabID: [UUID: UUID] = [:]
						for entry in entries {
							entriesBySessionID[entry.id] = entry
							preferredSessionIDByTabID[entry.tabID] = entry.id
							emittedSessionIDs.insert(entry.id)
						}
						continuation.yield(
							AgentSessionSidebarBuildBatch(
								entriesBySessionID: entriesBySessionID,
								preferredSessionIDByTabID: preferredSessionIDByTabID
							)
						)
						#if DEBUG
						yieldedBatchCount += 1
						yieldedEntryCount += entries.count
						preferredEntriesYielded += entries.count
						#endif
					}

					if let prioritizedTabID = request.prioritizedTabID,
						let prioritizedEntry = projection.preferredEntryByTabID[prioritizedTabID] {
						#if DEBUG
						let yieldStartMS = services.timestampMSIfEnabled()
						#endif
						yieldBatch(entries: [prioritizedEntry])
						#if DEBUG
						if let yieldStartMS {
							yieldDurationMS += services.elapsedMS( yieldStartMS)
						}
						prioritizedYielded = true
						#endif
					}

					var pending: [AgentSessionIndexEntry] = []
					for entry in projection.orderedPreferredEntries where !emittedSessionIDs.contains(entry.id) {
						try Task.checkCancellation()
						pending.append(entry)
						if pending.count >= effectiveBatchSize {
							#if DEBUG
							let yieldStartMS = services.timestampMSIfEnabled()
							#endif
							yieldBatch(entries: pending)
							#if DEBUG
							if let yieldStartMS {
								yieldDurationMS += services.elapsedMS( yieldStartMS)
							}
							#endif
							pending.removeAll(keepingCapacity: true)
						}
					}
					#if DEBUG
					let pendingYieldStartMS = services.timestampMSIfEnabled()
					#endif
					yieldBatch(entries: pending)
					#if DEBUG
					if let pendingYieldStartMS, !pending.isEmpty {
						yieldDurationMS += services.elapsedMS( pendingYieldStartMS)
					}
					#endif

					let nonPreferredEntries = projection.entriesBySessionID.values
						.filter { !emittedSessionIDs.contains($0.id) }
					guard nonPreferredEntries.isEmpty else {
						var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
						for entry in nonPreferredEntries {
							entriesBySessionID[entry.id] = entry
						}
						#if DEBUG
						let yieldStartMS = services.timestampMSIfEnabled()
						#endif
						continuation.yield(
							AgentSessionSidebarBuildBatch(
								entriesBySessionID: entriesBySessionID,
								preferredSessionIDByTabID: [:]
							)
						)
						#if DEBUG
						if let yieldStartMS {
							yieldDurationMS += services.elapsedMS( yieldStartMS)
						}
						yieldedBatchCount += 1
						yieldedEntryCount += nonPreferredEntries.count
						nonPreferredEntriesYielded += nonPreferredEntries.count
						logYieldComplete()
						#endif
						continuation.finish()
						return
					}
					#if DEBUG
					logYieldComplete()
					#endif
					continuation.finish()
				} catch {
					#if DEBUG
					if !Task.isCancelled {
						services.observe(
							"agentSessionIndex.streamFailure",
							[

								"batches": "\(yieldedBatchCount)",
								"entriesYielded": "\(yieldedEntryCount)",
								"total": streamStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured",
								"error": String(describing: error)
							]
						)
					}
					#endif
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	public func buildSidebarIndex(
		_ request: AgentSessionSidebarQuery,
        isolation: isolated (any Actor)? = #isolation
	) async throws -> AgentSessionSidebarBuildResult {
		var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
		var preferredSessionIDByTabID: [UUID: UUID] = [:]
		for try await batch in buildSidebarIndexStream(request, batchSize: Int.max) {
			entriesBySessionID.merge(batch.entriesBySessionID) { _, new in new }
			preferredSessionIDByTabID.merge(batch.preferredSessionIDByTabID) { _, new in new }
		}
		return AgentSessionSidebarBuildResult(
			entriesBySessionID: entriesBySessionID,
			preferredSessionIDByTabID: preferredSessionIDByTabID
		)
	}

	public func buildPrioritizedSidebarIndex(
		_ request: AgentSessionSidebarQuery,
        isolation: isolated (any Actor)? = #isolation
	) async throws -> AgentSessionSidebarBuildResult {
		#if DEBUG
		let targetedStartMS = services.timestampMSIfEnabled()
		func logTargetedBuilt(
			source: String,
			tabID: UUID?,
			explicitSessionID: UUID?,
			recordsScanned: Int?,
			result: AgentSessionSidebarBuildResult
		) {
			services.observe(
				"agentSessionIndex.prioritizedTargetedBuilt",
				[

					"tabID": services.shortID(tabID),
					"explicitSession": services.shortID(explicitSessionID),
					"source": source,
					"recordsScanned": recordsScanned.map { "\($0)" } ?? "unknown",
					"entries": "\(result.entriesBySessionID.count)",
					"preferredTabs": "\(result.preferredSessionIDByTabID.count)",
					"duration": targetedStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured"
				]
			)
		}
		#endif

		guard request.validTabIDs.count == 1,
			let tabID = request.validTabIDs.first else {
			let result = try await buildSidebarIndex(request)
			#if DEBUG
			logTargetedBuilt(
				source: "fallbackFull",
				tabID: request.prioritizedTabID,
				explicitSessionID: nil,
				recordsScanned: nil,
				result: result
			)
			#endif
			return result
		}

		let tabName = request.tabNameByID[tabID]
		let explicitSessionID = request.boundSessionIDByTabID[tabID]
		if let fastRecords = try await services.fastRecords() {
			let projection = projectPrioritizedSidebarIndex(
				records: fastRecords.records,
				tabID: tabID,
				tabName: tabName,
				explicitSessionID: explicitSessionID
			)
			#if DEBUG
			logTargetedBuilt(
				source: fastRecords.source,
				tabID: tabID,
				explicitSessionID: explicitSessionID,
				recordsScanned: projection.recordsScanned,
				result: projection.result
			)
			#endif
			return projection.result
		}

		guard let explicitSessionID else {
			// Targeted restore is best-effort; without an explicit binding or a fast
			// metadata index, avoid rebuilding the full index on the foreground path.
			let result = AgentSessionSidebarBuildResult(
				entriesBySessionID: [:],
				preferredSessionIDByTabID: [:]
			)
			#if DEBUG
			logTargetedBuilt(
				source: "emptyNoIndex",
				tabID: tabID,
				explicitSessionID: nil,
				recordsScanned: 0,
				result: result
			)
			#endif
			return result
		}

		let record: Record?
		do {
			record = try await services.loadRecord(explicitSessionID)
		} catch let error as CancellationError {
			throw error
		} catch {
			record = nil
		}
		guard let record, let entry = services.entry(record, tabID, tabName ?? services.name(record)) else {
			let result = AgentSessionSidebarBuildResult(
				entriesBySessionID: [:],
				preferredSessionIDByTabID: [:]
			)
			#if DEBUG
			logTargetedBuilt(
				source: "missingExplicitSessionFile",
				tabID: tabID,
				explicitSessionID: explicitSessionID,
				recordsScanned: 0,
				result: result
			)
			#endif
			return result
		}

		let result = AgentSessionSidebarBuildResult(
			entriesBySessionID: [entry.id: entry],
			preferredSessionIDByTabID: [tabID: entry.id]
		)
		#if DEBUG
		logTargetedBuilt(
			source: "explicitSessionFile",
			tabID: tabID,
			explicitSessionID: explicitSessionID,
			recordsScanned: 1,
			result: result
		)
		#endif
		return result
	}

	private struct SidebarIndexProjection {
		let entriesBySessionID: [UUID: AgentSessionIndexEntry]
		let preferredEntryByTabID: [UUID: AgentSessionIndexEntry]
		let orderedPreferredEntries: [AgentSessionIndexEntry]
	}

	private struct PrioritizedSidebarProjection {
		let result: AgentSessionSidebarBuildResult
		let recordsScanned: Int
	}

	private func projectPrioritizedSidebarIndex(
		records: [Record],
		tabID: UUID,
		tabName: String?,
		explicitSessionID: UUID?
	) -> PrioritizedSidebarProjection {
		var recordsScanned = 0
		if let explicitSessionID {
			for record in records {
				recordsScanned += 1
				guard services.sessionID(record) == explicitSessionID else { continue }
				guard let entry = services.entry(record, tabID, tabName ?? services.name(record)) else {
					break
				}
				return PrioritizedSidebarProjection(
					result: AgentSessionSidebarBuildResult(
						entriesBySessionID: [entry.id: entry],
						preferredSessionIDByTabID: [tabID: entry.id]
					),
					recordsScanned: recordsScanned
				)
			}
			return PrioritizedSidebarProjection(
				result: AgentSessionSidebarBuildResult(
					entriesBySessionID: [:],
					preferredSessionIDByTabID: [:]
				),
				recordsScanned: recordsScanned
			)
		}

		var preferredEntry: AgentSessionIndexEntry?
		for record in records {
			recordsScanned += 1
			guard services.tabID(record) == tabID,
				let entry = services.entry(record, tabID, tabName ?? services.name(record)) else {
				continue
			}
			if let existing = preferredEntry {
				if AgentSessionSidebarOrdering.shouldPreferSidebarEntry(entry, over: existing) {
					preferredEntry = entry
				}
			} else {
				preferredEntry = entry
			}
		}

		guard let preferredEntry else {
			return PrioritizedSidebarProjection(
				result: AgentSessionSidebarBuildResult(
					entriesBySessionID: [:],
					preferredSessionIDByTabID: [:]
				),
				recordsScanned: recordsScanned
			)
		}

		return PrioritizedSidebarProjection(
			result: AgentSessionSidebarBuildResult(
				entriesBySessionID: [preferredEntry.id: preferredEntry],
				preferredSessionIDByTabID: [tabID: preferredEntry.id]
			),
			recordsScanned: recordsScanned
		)
	}

	private func projectSidebarIndex(
		records: [Record],
		request: AgentSessionSidebarQuery
	) -> SidebarIndexProjection {
		#if DEBUG
		let projectionStartMS = services.timestampMSIfEnabled()
		let sortStartMS = services.timestampMSIfEnabled()
		#endif
		let sortedRecords = services.sortedRecords(records)
		#if DEBUG
		let sortDurationMS = sortStartMS.map { services.elapsedMS( $0) }
		let recordMapStartMS = services.timestampMSIfEnabled()
		#endif
		var recordBySessionID: [UUID: Record] = [:]
		for record in sortedRecords where recordBySessionID[services.sessionID(record)] == nil {
			recordBySessionID[services.sessionID(record)] = record
		}
		#if DEBUG
		let recordMapDurationMS = recordMapStartMS.map { services.elapsedMS( $0) }
		let explicitStartMS = services.timestampMSIfEnabled()
		var explicitCandidates = 0
		var explicitEntries = 0
		#endif

		var entriesBySessionID: [UUID: AgentSessionIndexEntry] = [:]
		var preferredEntryByTabID: [UUID: AgentSessionIndexEntry] = [:]
		var explicitTabIDBySessionID: [UUID: UUID] = [:]

		for (tabID, sessionID) in request.boundSessionIDByTabID where request.validTabIDs.contains(tabID) {
			#if DEBUG
			explicitCandidates += 1
			#endif
			guard let record = recordBySessionID[sessionID],
				let entry = services.entry(record, tabID, request.tabNameByID[tabID] ?? services.name(record)) else {
				continue
			}
			explicitTabIDBySessionID[entry.id] = tabID
			entriesBySessionID[entry.id] = entry
			preferredEntryByTabID[tabID] = entry
			#if DEBUG
			explicitEntries += 1
			#endif
		}
		#if DEBUG
		let explicitDurationMS = explicitStartMS.map { services.elapsedMS( $0) }
		let preferredStartMS = services.timestampMSIfEnabled()
		var preferredCandidates = 0
		#endif

		let explicitlyBoundTabIDs = Set(preferredEntryByTabID.keys)
		for record in sortedRecords {
			guard let tabID = services.tabID(record),
				request.validTabIDs.contains(tabID) else {
				continue
			}
			#if DEBUG
			preferredCandidates += 1
			#endif
			if let explicitTabID = explicitTabIDBySessionID[services.sessionID(record)], explicitTabID != tabID {
				continue
			}
			guard let entry = services.entry(record, tabID, request.tabNameByID[tabID] ?? services.name(record)) else {
				continue
			}
			if entriesBySessionID[entry.id] == nil {
				entriesBySessionID[entry.id] = entry
			}
			guard !explicitlyBoundTabIDs.contains(tabID) else { continue }
			if let existing = preferredEntryByTabID[tabID] {
				if AgentSessionSidebarOrdering.shouldPreferSidebarEntry(entry, over: existing) {
					preferredEntryByTabID[tabID] = entry
				}
			} else {
				preferredEntryByTabID[tabID] = entry
			}
		}
		#if DEBUG
		let preferredDurationMS = preferredStartMS.map { services.elapsedMS( $0) }
		let orderedSortStartMS = services.timestampMSIfEnabled()
		#endif

		let orderedPreferredEntries = preferredEntryByTabID.values.sorted { lhs, rhs in
			let lhsActivity = AgentSessionSidebarOrdering.sidebarActivityDate(
				lastUserMessageAt: lhs.lastUserMessageAt,
				savedAt: lhs.savedAt
			)
			let rhsActivity = AgentSessionSidebarOrdering.sidebarActivityDate(
				lastUserMessageAt: rhs.lastUserMessageAt,
				savedAt: rhs.savedAt
			)
			if lhsActivity != rhsActivity {
				return lhsActivity > rhsActivity
			}
			if lhs.savedAt != rhs.savedAt {
				return lhs.savedAt > rhs.savedAt
			}
			if lhs.tabID.uuidString != rhs.tabID.uuidString {
				return lhs.tabID.uuidString < rhs.tabID.uuidString
			}
			return lhs.id.uuidString < rhs.id.uuidString
		}
		#if DEBUG
		let orderedSortDurationMS = orderedSortStartMS.map { services.elapsedMS( $0) }
		services.observe(
			"agentSessionIndex.projection",
			[

				"records": "\(records.count)",
				"sortedRecords": "\(sortedRecords.count)",
				"recordMapCount": "\(recordBySessionID.count)",
				"validTabs": "\(request.validTabIDs.count)",
				"boundSessions": "\(request.boundSessionIDByTabID.count)",
				"explicitCandidates": "\(explicitCandidates)",
				"explicitEntries": "\(explicitEntries)",
				"preferredCandidates": "\(preferredCandidates)",
				"preferredEntries": "\(preferredEntryByTabID.count)",
				"entries": "\(entriesBySessionID.count)",
				"orderedPreferred": "\(orderedPreferredEntries.count)",
				"sortDuration": sortDurationMS.map(services.formatMS) ?? "notMeasured",
				"recordMapDuration": recordMapDurationMS.map(services.formatMS) ?? "notMeasured",
				"explicitDuration": explicitDurationMS.map(services.formatMS) ?? "notMeasured",
				"preferredDuration": preferredDurationMS.map(services.formatMS) ?? "notMeasured",
				"orderedSortDuration": orderedSortDurationMS.map(services.formatMS) ?? "notMeasured",
				"total": projectionStartMS.map { services.formatElapsedMS( $0) } ?? "notMeasured"
			]
		)
		#endif

		return SidebarIndexProjection(
			entriesBySessionID: entriesBySessionID,
			preferredEntryByTabID: preferredEntryByTabID,
			orderedPreferredEntries: orderedPreferredEntries
		)
	}

}
