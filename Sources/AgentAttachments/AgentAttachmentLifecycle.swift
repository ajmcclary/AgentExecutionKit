import Foundation
import AgentRuntimeKit

public enum AgentAttachmentDisposition: Sendable, Equatable {
    case restoreToPending, deleteFiles, keepFiles
}

public enum AgentAttachmentTurnState: Sendable, Equatable {
    case idle
    case reserved(reservationID: UUID, attachments: [AgentImageAttachment])
    case consumed(reservationID: UUID, attachments: [AgentImageAttachment])
}

/// One session's attachment ownership. The caller serializes commands with its run state.
/// Effects are applied by the host, so file deletion and composer mutation cannot occur
/// until the provider-specific runner explicitly finalizes the reservation.
public struct AgentAttachmentLifecycle: Sendable {
    public private(set) var state: AgentAttachmentTurnState = .idle
    public private(set) var deferredCleanup: [AgentImageAttachment] = []

    public struct Effects: Sendable, Equatable {
        public let restoreToPending: [AgentImageAttachment]
        public let deleteFiles: [AgentImageAttachment]
        public let requiresSave: Bool
    }

    public init() {}

    @discardableResult
    public mutating func reserve(_ attachments: [AgentImageAttachment], reservationID: UUID = UUID()) -> UUID? {
        guard !attachments.isEmpty else { state = .idle; return nil }
        state = .reserved(reservationID: reservationID, attachments: attachments)
        return reservationID
    }

    /// Provider disconnect resets only the current turn; deferred files retain ownership.
    public mutating func discardReservation() { state = .idle }

    public mutating func markConsumed(reservationID: UUID?) {
        guard case let .reserved(storedID, attachments) = state else { return }
        if let reservationID, reservationID != storedID { return }
        state = .consumed(reservationID: storedID, attachments: attachments)
    }

    public mutating func stageDeferredCleanup(_ attachments: [AgentImageAttachment], enabled: Bool) {
        guard enabled, !attachments.isEmpty else { return }
        let existingIDs = Set(deferredCleanup.map(\.id))
        deferredCleanup.append(contentsOf: attachments.filter { !existingIDs.contains($0.id) })
    }

    /// Clearing chat discards deferred ownership without deleting files, as does a
    /// failed send whose attachments have been restored to the composer's pending list.
    public mutating func consumeDeferredCleanup(deleteFiles: Bool) -> [AgentImageAttachment] {
        let attachments = deferredCleanup
        deferredCleanup.removeAll()
        return deleteFiles ? attachments : []
    }

    /// A stale reservation cannot alter replacement-turn state or deferred cleanup.
    /// A nil ID deliberately addresses the current reservation for legacy run hooks.
    public mutating func finalize(reservationID: UUID? = nil, disposition: AgentAttachmentDisposition,
                                  pending: [AgentImageAttachment]) -> Effects? {
        let attachments: [AgentImageAttachment]
        switch state {
        case .idle:
            return Effects(restoreToPending: [], deleteFiles: consumeDeferredCleanup(deleteFiles: disposition == .deleteFiles), requiresSave: false)
        case .reserved(let storedID, let stored), .consumed(let storedID, let stored):
            if let reservationID, reservationID != storedID { return nil }
            attachments = stored
        }
        var restored: [AgentImageAttachment] = []
        var deleted: [AgentImageAttachment] = []
        switch disposition {
        case .restoreToPending:
            let existingIDs = Set(pending.map(\.id))
            restored = attachments.filter { !existingIDs.contains($0.id) }
            _ = consumeDeferredCleanup(deleteFiles: false)
        case .deleteFiles:
            let hadDeferred = !deferredCleanup.isEmpty
            deleted = consumeDeferredCleanup(deleteFiles: true)
            if !hadDeferred { deleted = attachments }
        case .keepFiles:
            _ = consumeDeferredCleanup(deleteFiles: false)
        }
        state = .idle
        return Effects(restoreToPending: restored, deleteFiles: deleted, requiresSave: true)
    }
}
