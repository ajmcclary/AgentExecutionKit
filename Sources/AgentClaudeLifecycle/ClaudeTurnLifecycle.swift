import Foundation
import Synchronization
import ClaudeRuntimeKit

/// Actor-confined execution authority around ClaudeRuntimeKit's deterministic
/// reconciliation. Hosts stamp at ingress, emit content, then apply the returned
/// batch. No task, UI, storage, transport or implicit configuration lives here.
public final class ClaudeTurnLifecycle {
	public struct Turn: Equatable, Sendable {
		public let id: UUID
		public let generation: ClaudeTurnGeneration
	}
	public enum Effect: Sendable {
		case completed(Turn, outcome: ClaudeTurnOutcome, trigger: ClaudeCompletionTrigger)
		case abandoned(Turn)
		case drift(ClaudeLifecycleDrift.Site)
	}
	/// A single-use, owner/epoch-bound capability. Copying the value cannot replay
	/// its effects, and a foreign owner or a replaced transport cannot apply it.
	public struct Batch: Sendable {
		public let observation: ClaudeShadowLifecycleRecord
		fileprivate let owner: UUID
		fileprivate let epoch: UUID
		fileprivate let claim = Claim()
	}
	fileprivate final class Claim: Sendable {
		private let consumed = Mutex(false)
		func take() -> Bool { consumed.withLock { value in
			guard !value else { return false }; value = true; return true
		} }
	}
	private let owner = UUID()
	private var epoch = UUID()
	private var stamper = ClaudeLifecycleIngressStamper()
	private var reconciler = ClaudeLifecycleReconciler()
	private var turns: ContiguousArray<Turn> = []
	private let historyCapacity: Int
	public private(set) var observations: [ClaudeShadowLifecycleRecord] = []
	public private(set) var observedInputCount = 0
	public private(set) var completions: [ClaudeReconciledCompletion] = []
	public init(historyCapacity: Int = 512) { self.historyCapacity = max(0, historyCapacity) }
	public var hasOpenTurns: Bool { !turns.isEmpty }
	public var pendingTurnCount: Int { turns.count }
	public var headTurnGeneration: ClaudeTurnGeneration? { turns.first?.generation }
	public var hasDeferredOutcomes: Bool { reconciler.hasDeferredOutcomes }
	public func generation(for id: UUID) -> ClaudeTurnGeneration? { turns.first { $0.id == id }?.generation }
	/// Reconnect stamping is separate from the transportReestablished signal, as in
	/// the original controller. Open records survive until explicit disposition.
	public func beginNewEpoch() { epoch = UUID(); stamper.beginNewEpoch() }
	@discardableResult
	public func openTurn(id: UUID = UUID()) -> Turn {
		let turn = Turn(id: id, generation: stamper.openTurn())
		turns.append(turn); reconciler.openTurn(turn.generation); return turn
	}
	public func ingest(_ input: ClaudeLifecycleInput, observedOutcome: ClaudeTurnOutcome? = nil) -> Batch {
		observedInputCount += 1
		let stamped = stamper.stamp(input)
		let record = ClaudeShadowLifecycleRecord(stamped: stamped,
			decisions: reconciler.reconcile(stamped, observedOutcome: observedOutcome))
		if observations.count < historyCapacity { observations.append(record) }
		return Batch(observation: record, owner: owner, epoch: epoch)
	}
	@discardableResult
	public func apply(_ batch: Batch, onEffect: (Effect) -> Void) -> Bool {
		guard batch.owner == owner, batch.epoch == epoch, batch.claim.take() else { return false }
		for decision in batch.observation.decisions {
			// A callback may establish a replacement transport. Do not apply the
			// rest of the retired batch to that transport's ledger or diagnostics.
			guard batch.epoch == epoch else { break }
			switch decision {
			case .observe, .ignoreReplay, .defer: break
			case .complete(let generation, let outcome, let trigger):
				guard let turn = consumeTurn(generation: generation) else {
					onEffect(.drift(.completionForUnknownGeneration)); continue
				}
				if completions.count < historyCapacity {
					completions.append(.init(turn: generation, outcome: outcome, trigger: trigger))
				}
				onEffect(.completed(turn, outcome: outcome, trigger: trigger))
			case .abandon(let generation):
				guard let turn = consumeTurn(generation: generation) else {
					onEffect(.drift(.completionForUnknownGeneration)); continue
				}
				onEffect(.abandoned(turn))
			case .quarantine(let site): onEffect(.drift(site))
			}
		}
		return true
	}
	/// Strict generation lookup; neither queue position nor recency resolves a
	/// completion. Removal precedes every host callback and recursive application.
	private func consumeTurn(generation: ClaudeTurnGeneration) -> Turn? {
		guard let index = turns.firstIndex(where: { $0.generation == generation }) else { return nil }
		return turns.remove(at: index)
	}
	public func clearTurns() {
		epoch = UUID() // Retire pending dispatch capabilities without restamping wire history.
		for turn in turns { reconciler.forgetTurn(turn.generation) }
		turns.removeAll(keepingCapacity: false)
	}
	/// Corruption fixture only: production never separates ledger and reconciler.
	@_spi(Testing) public func dropLedgerRecordForTesting(id: UUID) {
		guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
		turns.remove(at: index)
	}
}
