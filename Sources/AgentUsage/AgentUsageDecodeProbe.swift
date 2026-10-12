import Foundation
import Synchronization

/// Optional bounded-decoding evidence. Separate decoders may safely share a probe;
/// each decode still owns its own buffer and never shares mutable Decoder state.
public final class AgentUsageDecodeProbe: Sendable {
    public static let userInfoKey = CodingUserInfoKey(rawValue: "agentExecutionKit.usageDecodeProbe")!
    public struct Snapshot: Sendable, Equatable {
        public var rowsObserved: Int = 0
        public var peakBufferedRowCount: Int = 0
        public var malformedSummaryStructure: Bool = false
    }
    private let storage = Mutex(Snapshot())
    public init() {}
    public var snapshot: Snapshot { storage.withLock { $0 } }
    public var rowsObserved: Int { snapshot.rowsObserved }
    public var peakBufferedRowCount: Int { snapshot.peakBufferedRowCount }
    public var malformedSummaryStructure: Bool { snapshot.malformedSummaryStructure }
    func observeRow() { storage.withLock { $0.rowsObserved += 1 } }
    func observeBuffer(count: Int) { storage.withLock { $0.peakBufferedRowCount = max($0.peakBufferedRowCount, count) } }
    func markMalformedSummaryStructure() { storage.withLock { $0.malformedSummaryStructure = true } }
}
