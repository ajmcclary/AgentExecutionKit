import Foundation
import AgentClaudeProtocol
import AgentClaudeCapabilities

/// Executes the admitted epoch's separate permission-mode request. A successful
/// RPC without an echoed mode remains unconfirmed; request failure propagates.
public enum ClaudeNativePermissionMode {
    public struct Observation: Sendable {
        public let requestedMode: String
        public let roundTrip: ClaudePermissionModeRoundTrip
        public let response: ClaudeProtocolJSONObject
    }
    public static func apply(request: ClaudeProtocolJSONObject?,
            rpc: (ClaudeProtocolJSONObject) async throws -> ClaudeProtocolJSONObject,
            observe: (Observation) -> Void,
            isolation: isolated (any Actor)? = #isolation) async throws -> ClaudePermissionModeRoundTrip {
        guard let request, let requestedMode = try request.dictionary()["mode"] as? String else { return .notAttempted }
        let response = try await rpc(request)
        let roundTrip = ClaudePermissionModeRoundTrip.classify(requestedMode: requestedMode, response: try response.dictionary())
        observe(.init(requestedMode: requestedMode, roundTrip: roundTrip, response: response))
        return roundTrip
    }
}
