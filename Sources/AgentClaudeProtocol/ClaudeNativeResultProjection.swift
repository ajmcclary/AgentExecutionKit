import Foundation
import AIClientKit
import ClaudeRuntimeKit

public enum ClaudeNativeResultProjection {
	public static func project(_ events: [ClaudeRuntimeEvent]) -> [AIStreamResult] {
		var out: [AIStreamResult] = []
		// The billed-turn aggregate arrives as its own event immediately before
		// `.result`; the results lane folds both into one `message_stop`. Held here
		// so the projection can rejoin them.
		var pendingTurnAggregate: ClaudeRuntimeEvent.UsageEvent?

		for event in events {
			switch event {
			case .systemInit:
				out.append(AIStreamResult(type: AIStreamResult.lifecycleType, text: "initialized"))
			case .assistantText(let a):
				out.append(AIStreamResult(type: "content", text: a.text))

			// F2.5b — stream sub-family. All three project IMMEDIATELY.
			//
			// None of them reads `pendingTurnAggregate`. That aggregate belongs
			// exclusively to the top-level `.result`: it is the BILLED turn total,
			// while these are per-message stream boundaries, and a turn may contain
			// several. Letting a stream boundary consume it would attach billing
			// figures to the wrong result and leave `.result` with none.
			case .stream(let stream):
				switch stream {
				case .contentDelta(_, _, let text, _):
					// One result per chunk. Never joined with adjacent deltas, and
					// never suppressed because the complete assistant message will
					// repeat the text — the results lane emits both.
					out.append(AIStreamResult(type: "content", text: text))
				case .messageDeltaStop(_, let stopReason, _):
					out.append(AIStreamResult(type: "message_stop", text: nil, stopReason: stopReason))
				case .messageStop:
					// The wire frame carries no stop reason; the results lane emits
					// a bare message_stop, so stopReason stays nil rather than
					// inheriting the preceding message_delta's value.
					out.append(AIStreamResult(type: "message_stop", text: nil))
				}
			case .toolUse(let t):
				guard t.source == .complete else { continue } // streamed → no result
				// COPY the stamped identity. Before F2.5 this dropped it entirely, and
				// ComparableResult did not compare the field, so the gate was blind.
				out.append(AIStreamResult(type: "tool_call", text: nil, toolName: t.name,
										  toolArgs: t.input, toolInvocationID: t.invocationID,
										  toolArgsJSON: t.input))
			case .usage(let u):
				switch u.identity.phase {
				case .assistantSnapshot:
					// Live context reading — projects to a standalone usage result.
					out.append(AIStreamResult(
						type: "usage",
						text: nil,
						promptTokens: u.breakdown.inputTokens,
						completionTokens: u.breakdown.outputTokens,
						contextUsedTokens: u.breakdown.contextUsedTokens
					))
				case .turnAggregate:
					// Rides the following `.result`'s message_stop; never standalone.
					pendingTurnAggregate = u
				}
			// --- F2.5 families. Every LEGACY SPELLING lives here, never in core:
			// the joined display strings, the `system`-row collapses, and routine
			// suppression. Core carries the parsed facts; this reassembles the
			// exact AIStreamResult the results lane produces.
			case .runtime(let runtime):
				switch runtime {
				case .sessionStateChanged(let state, _):
					out.append(AIStreamResult(type: "session_state_changed", text: state))
				case .compactBoundary(let trigger, let preTokens, _):
					var fragments: [String] = ["Context compacted"]
					if let trigger, !trigger.isEmpty { fragments.append("trigger: \(trigger)") }
					if let preTokens, preTokens > 0 { fragments.append("at ~\(preTokens) tokens") }
					out.append(AIStreamResult(type: "system", text: fragments.joined(separator: " — ")))
				}
			case .task(let task):
				switch task {
				case .started(let taskID, let description, _):
					let fragments = ["Task started", taskID, description]
						.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
						.filter { !$0.isEmpty }
					if !fragments.isEmpty {
						out.append(AIStreamResult(type: "system", text: fragments.joined(separator: " — ")))
					}
				case .notification(let taskID, let status, let summary, _):
					let fragments = ["Task update", taskID, status, summary]
						.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
						.filter { !$0.isEmpty }
					if !fragments.isEmpty {
						out.append(AIStreamResult(type: "system", text: fragments.joined(separator: " — ")))
					}
				case .progress(let taskID, let fragments, _):
					// Two legacy spellings from one event: the joined fragments, or —
					// when there is no descriptive text at all — "Task <id>". Omitting
					// the fallback would drop the row entirely for id-only frames.
					if fragments.isEmpty {
						guard let taskID = taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
							  !taskID.isEmpty else { continue }
						out.append(AIStreamResult(type: "task_progress", text: "Task \(taskID)"))
					} else {
						out.append(AIStreamResult(type: "task_progress", text: fragments.joined(separator: " — ")))
					}
				}
			case .tool(let tool):
				switch tool {
				case .summary(_, _, let summary, _):
					// The stamped invocationID is deliberately NOT copied: the legacy
					// lane's `system` row carries no invocation id, and parity is the
					// contract. Core still holds it so the normalized lane can relate a
					// summary to its invocation.
					guard !summary.isEmpty else { continue }
					out.append(AIStreamResult(type: "system", text: "Tool summary — \(summary)"))
				}
			case .telemetry(let telemetry):
				switch telemetry {
				case .rateLimit(let status, let rateLimitType, let overageStatus, _):
					// ROUTINE SUPPRESSION IS A PROJECTION DECISION. Core carried the
					// "allowed" fact so it was never lost; the results lane simply
					// does not surface it, and neither does this.
					guard status?.lowercased() != "allowed" else { continue }
					let fragments = ["Rate limit", status, rateLimitType, overageStatus]
						.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
						.filter { !$0.isEmpty }
					guard !fragments.isEmpty else { continue }
					out.append(AIStreamResult(type: "system", text: fragments.joined(separator: " — ")))
				case .authStatus(let isAuthenticating, let output, let error, let status, let message, _):
					if let isAuthenticating {
						var fragments: [String] = [isAuthenticating ? "Authenticating" : "Authenticated"]
						let joinedOutput = output.joined(separator: " ")
						if !joinedOutput.isEmpty { fragments.append(joinedOutput) }
						if let error, !error.isEmpty { fragments.append(error) }
						out.append(AIStreamResult(type: "auth_status", text: fragments.joined(separator: " — ")))
					} else {
						// The bare status/message shape. Joined with the same separator
						// but WITHOUT the Authenticating/Authenticated prefix, matching
						// the results lane's second branch.
						let parts = [status, message]
							.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
							.filter { !$0.isEmpty }
						guard !parts.isEmpty else { continue }
						out.append(AIStreamResult(type: "auth_status", text: parts.joined(separator: " — ")))
					}
				}
			case .status(let status):
				// The "compacting" -> "Compacting context" rewrite is a LEGACY
				// SPELLING and belongs here, not in core.
				guard let raw = status.status?.trimmingCharacters(in: .whitespacesAndNewlines),
					  !raw.isEmpty, raw != "null" else { continue }
				let text = raw.caseInsensitiveCompare("compacting") == .orderedSame
					? "Compacting context"
					: raw
				out.append(AIStreamResult(type: "status", text: text))
			case .failure(let failure):
				guard !failure.message.isEmpty else { continue }
				out.append(AIStreamResult(type: "error", text: failure.message))
			case .toolResult(let r):
				// `text` stays nil: the results lane puts the payload in toolOutput and
				// toolResultJSON only. Setting text here would have been an invisible
				// divergence until the goldens started comparing every field.
				out.append(AIStreamResult(
					type: "tool_result",
					text: nil,
					toolName: r.toolName,
					toolOutput: r.output,
					toolInvocationID: r.invocationID,
					toolResultJSON: r.output,
					toolIsError: r.isError
				))
			case .toolProgress(let p):
				let fragments = [p.toolName, p.status, p.detail]
					.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty }
				guard !fragments.isEmpty else { continue }
				out.append(AIStreamResult(
					type: "tool_progress",
					text: fragments.joined(separator: " — "),
					toolName: p.toolName
				))
			case .result(let r):
				if let text = r.text, !text.isEmpty {
					out.append(AIStreamResult(type: "final_content", text: text))
				}
				// contextUsedTokens stays nil: a billed-turn aggregate is not a live
				// context snapshot. This mirrors parseResultMessage exactly.
				out.append(AIStreamResult(
					type: "message_stop",
					text: nil,
					promptTokens: pendingTurnAggregate?.breakdown.inputTokens,
					completionTokens: pendingTurnAggregate?.breakdown.outputTokens,
					cost: pendingTurnAggregate?.costUSD,
					providerSessionID: r.sessionID,
					stopReason: r.stopReason,
					modelContextWindow: pendingTurnAggregate?.modelContextWindow
				))
				pendingTurnAggregate = nil
			}
		}
		return out
	}
}
