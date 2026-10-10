import Foundation
import Synchronization

/// Reserve before installing a cancellation handler. Each slot remembers early
/// cancellation/completion, so registration cannot lose either race.
final class TurnSettlementStore: Sendable {
	final class Slot: Sendable {
		private enum State: Sendable { case reserved, waiting(CheckedContinuation<Void, any Error>), completed(Result<Void, any Error>) }
		let id = UUID()
		private let state = Mutex<State>(.reserved)
		func install(_ continuation: CheckedContinuation<Void, any Error>) {
			let completed = state.withLock { state -> Result<Void, any Error>? in
				if case .completed(let result) = state { return result }
				state = .waiting(continuation); return nil
			}
			if let completed { continuation.resume(with: completed) }
		}
		func complete(_ result: Result<Void, any Error>) {
			let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
				switch state {
				case .completed: return nil
				case .reserved: state = .completed(result); return nil
				case .waiting(let continuation): state = .completed(result); return continuation
				}
			}
			continuation?.resume(with: result)
		}
	}
	private struct State: Sendable { var active: UUID?; var slots: [UUID: [UUID: Slot]] = [:] }
	private let state = Mutex(State())
	var active: UUID? { state.withLock { $0.active } }
	var waiterCount: Int { state.withLock { $0.slots.values.reduce(0) { $0 + $1.count } } }
	func begin(_ id: UUID) -> Bool {
		state.withLock { state in guard state.active == nil else { return false }; state.active = id; return true }
	}
	func reserve(_ turn: UUID) -> Slot? {
		state.withLock { state in
			guard state.active == turn else { return nil }
			let slot = Slot(); state.slots[turn, default: [:]][slot.id] = slot; return slot
		}
	}
	func cancel(_ turn: UUID, slot: Slot) {
		state.withLock { state in
			state.slots[turn]?[slot.id] = nil
			if state.slots[turn]?.isEmpty == true { state.slots[turn] = nil }
		}
		slot.complete(.failure(CancellationError()))
	}
	func settle(_ turn: UUID, result: Result<Void, any Error>) {
		let slots = state.withLock { state -> [Slot] in
			if state.active == turn { state.active = nil }
			return Array(state.slots.removeValue(forKey: turn)?.values ?? [:].values)
		}
		for slot in slots { slot.complete(result) }
	}
	func retire(with error: any Error) {
		let slots = state.withLock { state -> [Slot] in
			state.active = nil
			let slots = state.slots.values.flatMap { $0.values }; state.slots.removeAll(); return slots
		}
		for slot in slots { slot.complete(.failure(error)) }
	}
	deinit { retire(with: CancellationError()) }
}
