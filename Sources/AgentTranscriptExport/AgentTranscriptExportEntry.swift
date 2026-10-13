import Foundation
import AgentRuntimeKit

/// A host-materialized entry. XML previews and migrated session rows can differ
/// (for example a tool-call preview paired with a completed tool-result row).
public struct AgentTranscriptExportEntry: Sendable {
    public let migratedItem: AgentChatItem?
    public let sourceRowID: UUID?
    public let xmlItems: [AgentChatItem]
    public let turnID: UUID?
    public let isToolBoundary: Bool

    public init(migratedItem: AgentChatItem?, sourceRowID: UUID?, xmlItems: [AgentChatItem],
                turnID: UUID?, isToolBoundary: Bool) {
        self.migratedItem = migratedItem; self.sourceRowID = sourceRowID
        self.xmlItems = xmlItems; self.turnID = turnID; self.isToolBoundary = isToolBoundary
    }
}
