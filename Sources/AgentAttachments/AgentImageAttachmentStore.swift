import Foundation
import CryptoKit
import UniformTypeIdentifiers
import AgentRuntimeKit

public struct AgentImageFingerprint: Hashable, Sendable {
    public let byteCount: Int64
    public let digestHex: String
    public init(byteCount: Int64, digestHex: String) { self.byteCount = byteCount; self.digestHex = digestHex }
}

/// Hosts supply storage roots on every operation. Implementations never infer an app
/// namespace or read settings, credentials, or the process environment.
public protocol AgentAttachmentFileSystem: Sendable {
    func isImageFile(_ url: URL) -> Bool
    func fingerprint(_ url: URL) -> AgentImageFingerprint?
    func createDirectory(_ url: URL) throws
    func copy(from source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
}

public struct FoundationAgentAttachmentFileSystem: AgentAttachmentFileSystem {
    public init() {}
    public func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type.conforms(to: .image) }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }
    public func fingerprint(_ url: URL) -> AgentImageFingerprint? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let digestHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AgentImageFingerprint(byteCount: byteCount, digestHex: digestHex)
    }
    public func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    public func copy(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

public struct AgentImageAttachmentStore: Sendable {
    public enum Error: LocalizedError, Sendable {
        case invalidSourceURL, sourceIsNotImage, failedToCopy
        public var errorDescription: String? {
            switch self {
            case .invalidSourceURL: return "Image source must be a local file URL."
            case .sourceIsNotImage: return "Only image files can be attached."
            case .failedToCopy: return "Failed to import the selected image."
            }
        }
    }
    public struct ImportResult: Sendable {
        public let attachment: AgentImageAttachment
        public let fileURL: URL
    }
    public struct ImportFailure: Sendable {
        public let sourceURL: URL
        public let description: String
    }
    public struct BatchResult: Sendable {
        public let attachments: [AgentImageAttachment]
        public let failures: [ImportFailure]
    }
    private let fileSystem: any AgentAttachmentFileSystem
    private let newID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    public init(fileSystem: any AgentAttachmentFileSystem = FoundationAgentAttachmentFileSystem(),
                newID: @escaping @Sendable () -> UUID = { UUID() }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem; self.newID = newID; self.now = now
    }

    public func importImageFile(sourceURL: URL, storageRoot: URL) throws -> ImportResult {
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL else { throw Error.invalidSourceURL }
        guard fileSystem.isImageFile(source) else { throw Error.sourceIsNotImage }
        let root = storageRoot.standardizedFileURL
        try fileSystem.createDirectory(root)
        let sourceExtension = source.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let destination = root.appendingPathComponent(newID().uuidString).appendingPathExtension(sourceExtension.isEmpty ? "png" : sourceExtension)
        do { try fileSystem.copy(from: source, to: destination) } catch { throw Error.failedToCopy }
        return ImportResult(attachment: AgentImageAttachment(id: newID(), source: .localFile(path: destination.path), title: source.lastPathComponent, createdAt: now()), fileURL: destination)
    }

    /// Duplicate source paths and identical bytes are ignored across both the batch
    /// and existing pending attachments. An unavailable fingerprint never blocks import.
    public func importImages(_ sources: [URL], pending: [AgentImageAttachment], storageRoot: URL) -> BatchResult {
        var seenPaths: Set<String> = []
        var seenFingerprints: Set<AgentImageFingerprint> = []
        for attachment in pending {
            guard case let .localFile(path) = attachment.source else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if !url.path.isEmpty { seenPaths.insert(url.path) }
            if let fingerprint = fileSystem.fingerprint(url) { seenFingerprints.insert(fingerprint) }
        }
        var attachments: [AgentImageAttachment] = []
        var failures: [ImportFailure] = []
        for sourceURL in sources {
            let source = sourceURL.standardizedFileURL
            if !source.path.isEmpty, seenPaths.contains(source.path) { continue }
            let fingerprint = fileSystem.fingerprint(source)
            if let fingerprint, seenFingerprints.contains(fingerprint) { continue }
            do {
                let result = try importImageFile(sourceURL: source, storageRoot: storageRoot)
                if !source.path.isEmpty { seenPaths.insert(source.path) }
                if let importedFingerprint = fingerprint ?? fileSystem.fingerprint(result.fileURL) {
                    if seenFingerprints.contains(importedFingerprint) {
                        try? fileSystem.remove(result.fileURL)
                        continue
                    }
                    seenFingerprints.insert(importedFingerprint)
                }
                attachments.append(result.attachment)
            } catch { failures.append(ImportFailure(sourceURL: source, description: error.localizedDescription)) }
        }
        return BatchResult(attachments: attachments, failures: failures)
    }

    /// Preserve the existing lexical managed-root rule: only local files strictly
    /// below this root are removed. Remote references and sibling prefixes survive.
    public func clearConsumedLocalFiles(_ attachments: [AgentImageAttachment], storageRoot: URL) {
        guard !attachments.isEmpty else { return }
        let root = storageRoot.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var urls: Set<URL> = []
        for attachment in attachments {
            guard case let .localFile(path) = attachment.source else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.path.hasPrefix(prefix) { urls.insert(url) }
        }
        for url in urls { try? fileSystem.remove(url) }
    }
}
