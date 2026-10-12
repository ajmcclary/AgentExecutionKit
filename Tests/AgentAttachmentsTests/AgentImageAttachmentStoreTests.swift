import XCTest
import Foundation
import AgentRuntimeKit
import AgentAttachments

final class AgentImageAttachmentStoreTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func write(_ root: URL, _ name: String, bytes: [UInt8] = [137,80,78,71]) throws -> URL {
        let url = root.appendingPathComponent(name); try Data(bytes).write(to: url); return url
    }
    func testImportPreservesBytesTitleLowercasedExtensionAndInjectedMetadata() throws {
        try withRoot { root in
            let source = try write(root, "screen.PNG"), managed = root.appendingPathComponent("host/images", isDirectory: true)
            let id = UUID(), date = Date(timeIntervalSince1970: 123)
            let store = AgentImageAttachmentStore(newID: { id }, now: { date })
            let result = try store.importImageFile(sourceURL: source, storageRoot: managed)
            XCTAssertEqual(result.fileURL, managed.appendingPathComponent(id.uuidString).appendingPathExtension("png"))
            XCTAssertEqual(try Data(contentsOf: result.fileURL), try Data(contentsOf: source))
            XCTAssertEqual(result.attachment, AgentImageAttachment(id: id, source: .localFile(path: result.fileURL.path), title: "screen.PNG", createdAt: date))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }
    func testRemoteURLFailsBeforeCreatingManagedDirectory() throws {
        try withRoot { root in
            let managed = root.appendingPathComponent("images")
            XCTAssertThrowsError(try AgentImageAttachmentStore().importImageFile(sourceURL: URL(string: "https://example.com/image.png")!, storageRoot: managed)) {
                XCTAssertEqual($0.localizedDescription, "Image source must be a local file URL.")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        }
    }
    func testNonImageRejectedBeforeCreatingManagedDirectory() throws {
        try withRoot { root in
            let source = try write(root, "notes.txt"), managed = root.appendingPathComponent("images")
            XCTAssertThrowsError(try AgentImageAttachmentStore().importImageFile(sourceURL: source, storageRoot: managed)) {
                XCTAssertEqual($0.localizedDescription, "Only image files can be attached.")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
        }
    }
    func testMissingImageMapsCopyFailureToLegacyDescription() throws {
        try withRoot { root in
            XCTAssertThrowsError(try AgentImageAttachmentStore().importImageFile(sourceURL: root.appendingPathComponent("missing.png"), storageRoot: root.appendingPathComponent("images"))) {
                XCTAssertEqual($0.localizedDescription, "Failed to import the selected image.")
            }
        }
    }
    func testDirectoryCreationErrorPropagatesWithoutCopyErrorMasking() throws {
        try withRoot { root in
            let source = try write(root, "screen.png"), blocker = try write(root, "file.txt")
            XCTAssertThrowsError(try AgentImageAttachmentStore().importImageFile(sourceURL: source, storageRoot: blocker.appendingPathComponent("images"))) {
                XCTAssertNotEqual($0.localizedDescription, "Failed to import the selected image.")
            }
        }
    }
    func testBatchDeduplicatesPathsAndIdenticalBytesAcrossDistinctSourcesAndPending() throws {
        try withRoot { root in
            let a = try write(root, "a.png"), b = try write(root, "b.png"), c = try write(root, "c.png", bytes: [1,2,3])
            let managed = root.appendingPathComponent("images")
            let store = AgentImageAttachmentStore()
            let first = store.importImages([a,a,b,c], pending: [], storageRoot: managed)
            XCTAssertEqual(first.attachments.count, 2)
            XCTAssertTrue(first.failures.isEmpty)
            let second = store.importImages([a,b,c], pending: first.attachments, storageRoot: managed)
            XCTAssertTrue(second.attachments.isEmpty)
            XCTAssertTrue(second.failures.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path).count, 2)
        }
    }
    func testBatchReportsBadSourcesAndStillImportsValidSourcesInOrder() throws {
        try withRoot { root in
            let bad = try write(root, "bad.txt"), good = try write(root, "good.png")
            let missing = root.appendingPathComponent("missing.png")
            let result = AgentImageAttachmentStore().importImages([bad,good,missing], pending: [], storageRoot: root.appendingPathComponent("images"))
            XCTAssertEqual(result.attachments.map(\.title), ["good.png"])
            XCTAssertEqual(result.failures.map(\.sourceURL), [bad,missing])
            XCTAssertEqual(result.failures.map(\.description), ["Only image files can be attached.", "Failed to import the selected image."])
        }
    }
    func testCleanupOnlyRemovesLocalFilesStrictlyWithinExplicitRoot() throws {
        try withRoot { root in
            let managed = root.appendingPathComponent("images", isDirectory: true)
            let sibling = root.appendingPathComponent("images-other", isDirectory: true)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            let inside = try write(managed, "one.png"), outside = try write(sibling, "two.png"), source = try write(root, "source.png")
            let attachments: [AgentImageAttachment] = [inside,inside,outside,source,managed,managed.appendingPathComponent("../source.png")].map { .init(source: .localFile(path: $0.path)) } + [.init(source: .url(inside.absoluteString))]
            AgentImageAttachmentStore().clearConsumedLocalFiles(attachments, storageRoot: managed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        }
    }
    func testHostRootsRemainIsolated() throws {
        try withRoot { root in
            let source = try write(root, "screen.png"), a = root.appendingPathComponent("app-a"), b = root.appendingPathComponent("app-b")
            let store = AgentImageAttachmentStore()
            let one = try store.importImageFile(sourceURL: source, storageRoot: a)
            let two = try store.importImageFile(sourceURL: source, storageRoot: b)
            store.clearConsumedLocalFiles([one.attachment,two.attachment], storageRoot: a)
            XCTAssertFalse(FileManager.default.fileExists(atPath: one.fileURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: two.fileURL.path))
        }
    }
    func testFingerprintPinsSHA256AndUnavailableFileFallback() throws {
        try withRoot { root in
            let url = try write(root, "image.png", bytes: [97,98,99])
            let fs = FoundationAgentAttachmentFileSystem()
            XCTAssertEqual(fs.fingerprint(url), .init(byteCount: 3, digestHex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
            XCTAssertNil(fs.fingerprint(root.appendingPathComponent("missing.png")))
            XCTAssertNil(fs.fingerprint(URL(string: "https://example.com/image.png")!))
        }
    }
    func testUnavailableFingerprintsStillDeduplicatePathsAndImportOtherImages() throws {
        try withRoot { root in
            let a = try write(root, "a.png"), b = try write(root, "b.png")
            let store = AgentImageAttachmentStore(fileSystem: NoFingerprintFileSystem())
            let result = store.importImages([a,a,b], pending: [], storageRoot: root.appendingPathComponent("images"))
            XCTAssertEqual(result.attachments.map(\.title), ["a.png","b.png"])
            XCTAssertTrue(result.failures.isEmpty)
        }
    }
    func testPostCopyFingerprintDedupRemovesRedundantImportedFile() throws {
        try withRoot { root in
            let source = try write(root, "source.png"), managed = root.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let existing = try write(managed, "existing.png")
            let store = AgentImageAttachmentStore(fileSystem: ImportedFingerprintOnlyFileSystem(root: managed))
            let result = store.importImages([source], pending: [.init(source: .localFile(path: existing.path))], storageRoot: managed)
            XCTAssertTrue(result.attachments.isEmpty)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: managed.path), ["existing.png"])
        }
    }
    func testExtensionlessHostClassifiedImageDefaultsToPNG() throws {
        try withRoot { root in
            let source = try write(root, "image")
            let result = try AgentImageAttachmentStore(fileSystem: NoFingerprintFileSystem()).importImageFile(sourceURL: source, storageRoot: root.appendingPathComponent("images"))
            XCTAssertEqual(result.fileURL.pathExtension, "png")
        }
    }
}
private struct NoFingerprintFileSystem: AgentAttachmentFileSystem {
    let fs = FoundationAgentAttachmentFileSystem()
    func isImageFile(_ url: URL) -> Bool { true }
    func fingerprint(_ url: URL) -> AgentImageFingerprint? { nil }
    func createDirectory(_ url: URL) throws { try fs.createDirectory(url) }
    func copy(from source: URL, to destination: URL) throws { try fs.copy(from: source, to: destination) }
    func remove(_ url: URL) throws { try fs.remove(url) }
}
private struct ImportedFingerprintOnlyFileSystem: AgentAttachmentFileSystem {
    let root: URL
    let fs = FoundationAgentAttachmentFileSystem()
    func isImageFile(_ url: URL) -> Bool { fs.isImageFile(url) }
    func fingerprint(_ url: URL) -> AgentImageFingerprint? { url.path.hasPrefix(root.path + "/") ? fs.fingerprint(url) : nil }
    func createDirectory(_ url: URL) throws { try fs.createDirectory(url) }
    func copy(from source: URL, to destination: URL) throws { try fs.copy(from: source, to: destination) }
    func remove(_ url: URL) throws { try fs.remove(url) }
}
