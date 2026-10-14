import Foundation
import AgentRuntimeKit

public struct AgentSessionSidebarFastRecords<Record: Sendable>: Sendable {
    public let records: [Record]
    public let source: String
    public init(records: [Record], source: String) { self.records = records; self.source = source }
}
public struct AgentSessionSidebarServices<Record: Sendable>: Sendable {
    public var loadRecords: @Sendable () async throws -> [Record]
    public var fastRecords: @Sendable () async throws -> AgentSessionSidebarFastRecords<Record>?
    public var loadRecord: @Sendable (UUID) async throws -> Record?
    public var sortedRecords: @Sendable ([Record]) -> [Record]
    public var sessionID: @Sendable (Record) -> UUID
    public var tabID: @Sendable (Record) -> UUID?
    public var name: @Sendable (Record) -> String
    public var entry: @Sendable (Record, UUID, String) -> AgentSessionIndexEntry?
    public var timestampMSIfEnabled: @Sendable () -> Double?
    public var shortID: @Sendable (UUID?) -> String
    public var formatMS: @Sendable (Double) -> String
    public var formatElapsedMS: @Sendable (Double) -> String
    public var elapsedMS: @Sendable (Double) -> Double
    public var observe: @Sendable (String, [String:String]) -> Void
    public init(loadRecords: @escaping @Sendable () async throws -> [Record],
                fastRecords: @escaping @Sendable () async throws -> AgentSessionSidebarFastRecords<Record>?,
                loadRecord: @escaping @Sendable (UUID) async throws -> Record?,
                sortedRecords: @escaping @Sendable ([Record]) -> [Record],
                sessionID: @escaping @Sendable (Record) -> UUID, tabID: @escaping @Sendable (Record) -> UUID?,
                name: @escaping @Sendable (Record) -> String,
                entry: @escaping @Sendable (Record, UUID, String) -> AgentSessionIndexEntry?,
                timestampMSIfEnabled: @escaping @Sendable () -> Double? = { nil },
                shortID: @escaping @Sendable (UUID?) -> String = { $0?.uuidString ?? "nil" },
                formatMS: @escaping @Sendable (Double) -> String = { String($0) },
                formatElapsedMS: @escaping @Sendable (Double) -> String = { String($0) },
                elapsedMS: @escaping @Sendable (Double) -> Double = { _ in 0 },
                observe: @escaping @Sendable (String, [String:String]) -> Void = { _,_ in }) {
        self.loadRecords = loadRecords; self.fastRecords = fastRecords; self.loadRecord = loadRecord
        self.sortedRecords = sortedRecords; self.sessionID = sessionID; self.tabID = tabID; self.name = name
        self.entry = entry; self.timestampMSIfEnabled = timestampMSIfEnabled; self.shortID = shortID
        self.formatMS = formatMS; self.formatElapsedMS = formatElapsedMS; self.elapsedMS = elapsedMS; self.observe = observe
    }
}
public struct AgentSessionSidebarQuery: Sendable {
    public let tabNameByID: [UUID:String]
    public let validTabIDs: Set<UUID>
    public let boundSessionIDByTabID: [UUID:UUID]
    public let prioritizedTabID: UUID?
    public init(tabNameByID: [UUID:String], validTabIDs: Set<UUID>, boundSessionIDByTabID: [UUID:UUID] = [:], prioritizedTabID: UUID? = nil) {
        self.tabNameByID = tabNameByID; self.validTabIDs = validTabIDs
        self.boundSessionIDByTabID = boundSessionIDByTabID; self.prioritizedTabID = prioritizedTabID
    }
}
public struct AgentSessionSidebarBuildBatch: Sendable {
    public let entriesBySessionID: [UUID:AgentSessionIndexEntry]
    public let preferredSessionIDByTabID: [UUID:UUID]
    public init(entriesBySessionID: [UUID:AgentSessionIndexEntry], preferredSessionIDByTabID: [UUID:UUID]) {
        self.entriesBySessionID = entriesBySessionID; self.preferredSessionIDByTabID = preferredSessionIDByTabID
    }
}
public struct AgentSessionSidebarBuildResult: Sendable {
    public let entriesBySessionID: [UUID:AgentSessionIndexEntry]
    public let preferredSessionIDByTabID: [UUID:UUID]
    public init(entriesBySessionID: [UUID:AgentSessionIndexEntry], preferredSessionIDByTabID: [UUID:UUID]) {
        self.entriesBySessionID = entriesBySessionID; self.preferredSessionIDByTabID = preferredSessionIDByTabID
    }
}
