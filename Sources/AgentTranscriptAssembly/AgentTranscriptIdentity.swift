import Foundation
import CryptoKit

/// Existing domain-separated stable UUIDs, preserving legacy span/summary/conclusion identities.
public enum AgentTranscriptIdentity {
    public static func summaryID(for turnID: UUID) -> UUID { uuid(seed: turnID.uuidString + ":middle-summary") }
    public static func conclusionID(for turnID: UUID) -> UUID { uuid(seed: turnID.uuidString + ":compact-conclusion") }
    public static func spanID(turnID: UUID, ordinal: Int) -> UUID { uuid(seed: turnID.uuidString + ":response-span:\(ordinal)") }
    private static func uuid(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8)); let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
