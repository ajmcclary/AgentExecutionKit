import Foundation
import Synchronization
import ProcessKit

/// Physical transport owned by one serialized actor. Mutating methods are
/// synchronous; consumer/waiter tasks capture only injected callbacks and values,
/// never this non-Sendable transport. Protocol framing and host policy stay above it.
public final class AgentNativeProcessTransport {
    public struct LaunchSpec: Sendable {
        public let command: String
        public let arguments: [String]
        public let environment: [String: String]
        public let workingDirectory: String?
        public init(command: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
            self.command = command; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
        }
    }
    public struct Lifecycle: Sendable {
        public let readPreflight: @Sendable (Int32, String) throws -> Void
        public let waitForTermination: @Sendable (Int32) async -> (exitCode: Int32, timedOut: Bool)?
        public let terminateAndReap: @Sendable (Int32) async -> Void
        public init(readPreflight: @escaping @Sendable (Int32, String) throws -> Void,
                    waitForTermination: @escaping @Sendable (Int32) async -> (exitCode: Int32, timedOut: Bool)?,
                    terminateAndReap: @escaping @Sendable (Int32) async -> Void) {
            self.readPreflight = readPreflight; self.waitForTermination = waitForTermination; self.terminateAndReap = terminateAndReap
        }
    }
    public enum TransportError: Error, Sendable { case unavailable, alreadyRunning, waiterAlreadyInstalled }

    /// Sealed cleanup ownership. Repeated/concurrent finish calls await the same
    /// task. The waiter reaps when installed; direct reaping is only a pre-waiter path.
    public final class TerminationLease: Sendable {
        private enum State: Sendable {
            case pending(SpawnedProcess, Task<Void, Never>?, @Sendable (Int32) async -> Void)
            case finishing(Task<Void, Never>)
        }
        private let state: Mutex<State>
        fileprivate init(process: SpawnedProcess, waiter: Task<Void, Never>?, directReap: @escaping @Sendable (Int32) async -> Void) {
            state = Mutex(.pending(process, waiter, directReap))
        }
        private func cleanupTask() -> Task<Void, Never> {
            state.withLock { state in
                switch state {
                case .finishing(let task): return task
                case .pending(let process, let waiter, let directReap):
                    let task = Task {
                        if let waiter { waiter.cancel(); await waiter.value }
                        else { await directReap(process.pid) }
                    }
                    state = .finishing(task)
                    return task
                }
            }
        }
        public func finish() async { await cleanupTask().value }
        deinit { _ = cleanupTask() }
    }

    private let lifecycle: Lifecycle
    private var process: SpawnedProcess?
    private var stdoutReader: ProcessPipeReader?
    private var stderrReader: ProcessPipeReader?
    private var waiter: Task<Void, Never>?
    public private(set) var generation: UInt64 = 0
    public var hasProcess: Bool { process != nil }
    public var hasWaiter: Bool { waiter != nil }
    public var pid: Int32? { process?.pid }

    public init(lifecycle: Lifecycle) { self.lifecycle = lifecycle }
    @discardableResult
    public func spawn(_ spec: LaunchSpec) throws -> Int32 {
        guard process == nil, waiter == nil else { throw TransportError.alreadyRunning }
        let child = try ProcessLauncher.spawn(command: spec.command, arguments: spec.arguments,
                                              environment: spec.environment, workingDirectory: spec.workingDirectory)
        generation &+= 1
        process = child
        return child.pid
    }
    public func startReaders(stdoutLabel: String, stderrLabel: String,
        onStdout: @escaping @Sendable (UInt64, Data) async -> Void,
        onStderr: @escaping @Sendable (UInt64, Data) async -> Void) throws {
        guard let process else { throw TransportError.unavailable }
        stdoutReader?.cancel(); stderrReader?.cancel()
        stdoutReader = nil; stderrReader = nil
        let generation = generation
        let stdout = ProcessPipeReader()
        try stdout.start(handle: process.stdout, label: stdoutLabel, preflight: lifecycle.readPreflight,
                         onChunk: { await onStdout(generation, $0) })
        stdoutReader = stdout
        let stderr = ProcessPipeReader()
        do {
            try stderr.start(handle: process.stderr, label: stderrLabel, preflight: lifecycle.readPreflight,
                             onChunk: { await onStderr(generation, $0) })
        } catch { stdoutReader?.cancel(); stdoutReader = nil; throw error }
        stderrReader = stderr
    }
    /// Install after the host's process registration. The callback carries its
    /// captured generation; the owner releases naturally-reaped state via observeExit.
    public func startWaiter(onExit: @escaping @Sendable (UInt64, Int32, Bool) async -> Void) throws {
        guard let process else { throw TransportError.unavailable }
        guard waiter == nil else { throw TransportError.waiterAlreadyInstalled }
        let wait = lifecycle.waitForTermination; let pid = process.pid; let generation = generation
        waiter = Task {
            let result = await wait(pid)
            await onExit(generation, result?.exitCode ?? 0, result?.timedOut ?? false)
        }
    }
    public func writeFrame(_ data: Data, expectedGeneration: UInt64? = nil) throws {
        guard expectedGeneration == nil || expectedGeneration == generation,
              let fd = process?.stdinDescriptor else { throw TransportError.unavailable }
        try FDWriteSupport.writeAll(data, to: fd)
    }
    /// Natural exit is already reaped. A stale exit may not clear a replacement.
    @discardableResult
    public func observeExit(expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration, process != nil else { return false }
        detachReadersAndInput()
        process = nil; waiter = nil
        return true
    }
    /// Releases state synchronously before awaiting cleanup. The returned lease
    /// must be finished by the owner; an old lease cannot touch a replacement.
    public func invalidate(expectedGeneration: UInt64? = nil) -> TerminationLease? {
        guard expectedGeneration == nil || expectedGeneration == generation, let process else { return nil }
        detachReadersAndInput()
        let lease = TerminationLease(process: process, waiter: waiter, directReap: lifecycle.terminateAndReap)
        self.process = nil; waiter = nil
        return lease
    }
    deinit {
        detachReadersAndInput()
        if let process {
            let lease = TerminationLease(process: process, waiter: waiter, directReap: lifecycle.terminateAndReap)
            Task { await lease.finish() }
        }
    }
    private func detachReadersAndInput() {
        stdoutReader?.cancel(); stderrReader?.cancel()
        stdoutReader = nil; stderrReader = nil
        process?.stdout.readabilityHandler = nil
        process?.stderr.readabilityHandler = nil
        process?.stdin?.closeFile()
    }
}
