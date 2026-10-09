import Foundation
import Darwin
import ProcessKit

public actor ProcessRegistry {
	private var children: [pid_t: SpawnedProcess] = [:]

	public init() {}

	public func add(_ process: SpawnedProcess) {
		children[process.pid] = process
	}

	public func remove(pid: pid_t) -> SpawnedProcess? {
		children.removeValue(forKey: pid)
	}

	public func removeAll() -> [SpawnedProcess] {
		let current = Array(children.values)
		children.removeAll()
		return current
	}

	public func current() -> [SpawnedProcess] {
		Array(children.values)
	}
}
