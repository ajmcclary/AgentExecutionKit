import XCTest
import Foundation
import AgentRuntimeKit
import AgentAttachments

final class AgentAttachmentLifecycleTests: XCTestCase {
    private func image(_ name: String) -> AgentImageAttachment { .init(source: .localFile(path: "/managed/\(name).png")) }

    func testCancellationRestoresOnlyMissingImagesAheadOfNewComposerImages() {
        let first = image("first"), second = image("second"), newer = image("newer")
        var lifecycle = AgentAttachmentLifecycle()
        let id = lifecycle.reserve([first, second])
        lifecycle.stageDeferredCleanup([first], enabled: true)
        let effect = lifecycle.finalize(reservationID: id, disposition: .restoreToPending, pending: [second, newer])
        XCTAssertEqual(effect?.restoreToPending, [first])
        XCTAssertEqual((effect?.restoreToPending ?? []) + [second, newer], [first, second, newer])
        XCTAssertEqual(effect?.deleteFiles, [])
        XCTAssertEqual(effect?.requiresSave, true)
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.deferredCleanup, [])
    }
    func testInterruptedConsumedTurnDeletesReservationWithoutDeferredBatch() {
        let attachment = image("consumed")
        var lifecycle = AgentAttachmentLifecycle()
        let id = lifecycle.reserve([attachment])
        lifecycle.markConsumed(reservationID: id)
        XCTAssertEqual(lifecycle.state, .consumed(reservationID: id!, attachments: [attachment]))
        XCTAssertEqual(lifecycle.finalize(reservationID: id, disposition: .deleteFiles, pending: [])?.deleteFiles, [attachment])
    }
    func testDeferredProviderBatchTakesPrecedenceOverReservedBatch() {
        let reserved = image("reserved"), deferred = image("deferred")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.reserve([reserved])
        lifecycle.stageDeferredCleanup([deferred], enabled: true)
        XCTAssertEqual(lifecycle.finalize(disposition: .deleteFiles, pending: [])?.deleteFiles, [deferred])
        XCTAssertEqual(lifecycle.deferredCleanup, [])
    }
    func testLateFinalizeCannotDeleteReplacementReservationOrItsDeferredFiles() {
        let older = image("older"), newer = image("newer")
        var lifecycle = AgentAttachmentLifecycle()
        let oldID = lifecycle.reserve([older])
        let newID = lifecycle.reserve([newer])
        lifecycle.stageDeferredCleanup([newer], enabled: true)
        XCTAssertNil(lifecycle.finalize(reservationID: oldID, disposition: .deleteFiles, pending: []))
        XCTAssertEqual(lifecycle.state, .reserved(reservationID: newID!, attachments: [newer]))
        XCTAssertEqual(lifecycle.deferredCleanup, [newer])
    }
    func testLateConsumptionDoesNotConsumeReplacementTurn() {
        let attachment = image("new")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.reserve([attachment])
        lifecycle.markConsumed(reservationID: UUID())
        guard case .reserved = lifecycle.state else { return XCTFail("Stale event consumed current reservation") }
    }
    func testLegacyNilIDAddressesCurrentReservation() {
        let attachment = image("legacy")
        var lifecycle = AgentAttachmentLifecycle()
        let id = lifecycle.reserve([attachment])!
        lifecycle.markConsumed(reservationID: nil)
        XCTAssertEqual(lifecycle.state, .consumed(reservationID: id, attachments: [attachment]))
        XCTAssertEqual(lifecycle.finalize(disposition: .restoreToPending, pending: [])?.restoreToPending, [attachment])
    }
    func testRepeatedConsumptionAndFinalizationDoNotRepeatDeletion() {
        let attachment = image("once")
        var lifecycle = AgentAttachmentLifecycle()
        let id = lifecycle.reserve([attachment])
        lifecycle.markConsumed(reservationID: id)
        lifecycle.markConsumed(reservationID: id)
        XCTAssertEqual(lifecycle.finalize(reservationID: id, disposition: .deleteFiles, pending: [])?.deleteFiles, [attachment])
        let again = lifecycle.finalize(reservationID: id, disposition: .deleteFiles, pending: [])
        XCTAssertEqual(again?.deleteFiles, [])
        XCTAssertEqual(again?.requiresSave, false)
    }
    func testKeepFilesClearsOwnershipWithoutDeletionOrRestoration() {
        let attachment = image("keep")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.reserve([attachment])
        lifecycle.stageDeferredCleanup([attachment], enabled: true)
        let effect = lifecycle.finalize(disposition: .keepFiles, pending: [])
        XCTAssertEqual(effect?.deleteFiles, [])
        XCTAssertEqual(effect?.restoreToPending, [])
        XCTAssertEqual(effect?.requiresSave, true)
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.deferredCleanup.isEmpty)
    }
    func testIdleFinalizationCanDrainDeferredFilesWithoutSchedulingSessionSave() {
        let attachment = image("idle")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.stageDeferredCleanup([attachment], enabled: true)
        let effect = lifecycle.finalize(disposition: .deleteFiles, pending: [])
        XCTAssertEqual(effect?.deleteFiles, [attachment])
        XCTAssertEqual(effect?.requiresSave, false)
    }
    func testIdleRestoreAndKeepDiscardDeferredOwnership() {
        for disposition in [AgentAttachmentDisposition.restoreToPending, .keepFiles] {
            var lifecycle = AgentAttachmentLifecycle()
            lifecycle.stageDeferredCleanup([image("idle")], enabled: true)
            let effect = lifecycle.finalize(disposition: disposition, pending: [])
            XCTAssertEqual(effect?.deleteFiles, [])
            XCTAssertEqual(effect?.restoreToPending, [])
            XCTAssertTrue(lifecycle.deferredCleanup.isEmpty)
        }
    }
    func testDeferredBatchesDeduplicateExistingIDsButPreserveIncomingMultiplicity() {
        let first = image("one"), second = image("two")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.stageDeferredCleanup([first], enabled: true)
        lifecycle.stageDeferredCleanup([first, second, second], enabled: true)
        XCTAssertEqual(lifecycle.deferredCleanup, [first, second, second])
    }
    func testDisabledCleanupDoesNotTakeDeferredOwnership() {
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.stageDeferredCleanup([image("disabled")], enabled: false)
        XCTAssertTrue(lifecycle.deferredCleanup.isEmpty)
    }
    func testEmptyReservationClearsTurnStateButRetainsAlreadyDeferredOwnership() {
        let attachment = image("retained")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.reserve([attachment])
        lifecycle.stageDeferredCleanup([attachment], enabled: true)
        XCTAssertNil(lifecycle.reserve([]))
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.deferredCleanup, [attachment])
    }
    func testSessionOwnersCannotMutateEachOther() {
        let first = image("first"), second = image("second")
        var a = AgentAttachmentLifecycle(), b = AgentAttachmentLifecycle()
        let aID = a.reserve([first]), bID = b.reserve([second])
        XCTAssertNil(b.finalize(reservationID: aID, disposition: .restoreToPending, pending: []))
        XCTAssertEqual(b.state, .reserved(reservationID: bID!, attachments: [second]))
        XCTAssertEqual(a.finalize(reservationID: aID, disposition: .restoreToPending, pending: [])?.restoreToPending, [first])
    }
    func testProviderDisconnectDiscardsReservationButRetainsDeferredCleanup() {
        let attachment = image("disconnect")
        var lifecycle = AgentAttachmentLifecycle()
        lifecycle.reserve([attachment])
        lifecycle.stageDeferredCleanup([attachment], enabled: true)
        lifecycle.discardReservation()
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.deferredCleanup, [attachment])
    }
    func testClearChatDiscardLeavesCurrentTurnReservationIntact() {
        let attachment = image("live")
        var lifecycle = AgentAttachmentLifecycle()
        let id = lifecycle.reserve([attachment])!
        lifecycle.stageDeferredCleanup([attachment], enabled: true)
        XCTAssertEqual(lifecycle.consumeDeferredCleanup(deleteFiles: false), [])
        XCTAssertEqual(lifecycle.state, .reserved(reservationID: id, attachments: [attachment]))
        XCTAssertTrue(lifecycle.deferredCleanup.isEmpty)
    }
}
