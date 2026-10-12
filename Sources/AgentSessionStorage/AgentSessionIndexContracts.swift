import Foundation

/// Index mechanisms depend on persisted record values, not a host's session/UI models.
public protocol AgentSessionIndexRecord: Codable, Sendable {
    var id: UUID { get }
    var filename: String { get }
    var activityDate: Date { get }
    var savedAt: Date { get }
    func matchesIndexedSessionMetadata(_ other: Self) -> Bool
}
public protocol AgentSessionIndexQuarantine: Codable, Sendable {
    init(filename: String, observedFileSize: Int64?, observedFileModificationDate: Date?, errorDescription: String, lastAttemptedAt: Date)
}
public protocol AgentSessionIndexDocument: Codable, Sendable {
    associatedtype Record: AgentSessionIndexRecord
    associatedtype Quarantine: AgentSessionIndexQuarantine
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get set }
    var generatedAt: Date { get set }
    var lastReconciledAt: Date? { get set }
    var entries: [Record] { get set }
    var quarantinedFiles: [Quarantine] { get set }
    init(schemaVersion: Int, generatedAt: Date, lastReconciledAt: Date?, entries: [Record], quarantinedFiles: [Quarantine])
}
public struct AgentSessionFileObservation: Sendable, Equatable {
    public let size: Int64?
    public let modified: Date?
    public init(size: Int64?, modified: Date?) { self.size = size; self.modified = modified }
}
public struct AgentSessionIndexLayout: Sendable {
    public let indexFilename: String
    public let sessionFilePrefix: String
    public let sessionFileExtension: String
    public init(indexFilename: String, sessionFilePrefix: String, sessionFileExtension: String) {
        self.indexFilename = indexFilename; self.sessionFilePrefix = sessionFilePrefix; self.sessionFileExtension = sessionFileExtension
    }
}
/// I/O and roots are explicit. Default Foundation I/O reads only supplied URLs;
/// directory creation and workspace/app namespace resolution remain host-owned.
public struct AgentSessionIndexFileSystem: Sendable {
    public let exists: @Sendable (URL) -> Bool
    public let read: @Sendable (URL) throws -> Data
    public let write: @Sendable (Data, URL) throws -> Void
    public let list: @Sendable (URL) throws -> [URL]
    public let observe: @Sendable (URL) -> AgentSessionFileObservation
    public init(exists: @escaping @Sendable (URL) -> Bool, read: @escaping @Sendable (URL) throws -> Data,
                write: @escaping @Sendable (Data, URL) throws -> Void, list: @escaping @Sendable (URL) throws -> [URL],
                observe: @escaping @Sendable (URL) -> AgentSessionFileObservation) {
        self.exists = exists; self.read = read; self.write = write; self.list = list; self.observe = observe
    }
    public static var foundation: Self {
        .init(exists: { FileManager.default.fileExists(atPath: $0.path) },
              read: { try Data(contentsOf: $0, options: .mappedIfSafe) },
              write: { try $0.write(to: $1, options: .atomic) },
              list: { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) },
              observe: { url in
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                  return .init(size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
              })
    }
}
