import Foundation

/// Orders admission and connection effects on the caller's actor. Concrete
/// launch policy, I/O, diagnostics and transcript presentation are host ports.
/// This shares the failure paths without introducing a second transport owner.
extension ClaudeNativeClientLifecycle {
    public func startTransport<Launch>(
        hasProcess: () -> Bool,
        resetEpoch: () -> Void,
        admit: () async throws -> Launch,
        adopt: (Launch) -> Void,
        spawn: (Launch) throws -> Int32,
        beginEpoch: () -> Void,
        startReaders: () throws -> Void,
        invalidateReaders: () async -> Void,
        registerPID: (Int32) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        await awaitTransportTeardown()
        guard !hasProcess() else { return }
        resetEpoch()
        let launch = try await admit()
        adopt(launch)
        let pid = try spawn(launch)
        beginEpoch()
        do { try startReaders() }
        catch {
            await invalidateReaders()
            throw ClaudeNativeClientError.initializationFailed("Failed to start Claude process readers: \(error.localizedDescription)")
        }
        await registerPID(pid)
    }

    /// Flushes buffered output before closing turns. Rechecks after both awaits:
    /// a failed flush can shut down, and teardown can yield to a new connection.
    /// The final error must precede the completions that it explains.
    public func handleEOF<CloseState>(
        generation: UInt64,
        currentGeneration: () -> UInt64,
        hasProcess: () -> Bool,
        observeEOF: () -> Void,
        flush: () -> String?,
        failProtocol: (String) async -> Void,
        prepareClose: () -> CloseState,
        teardownTransport: () async -> Void,
        finishClose: (CloseState) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        guard generation == currentGeneration(), hasProcess(), !isShuttingDown else { return }
        observeEOF()
        if let failure = flush() { await failProtocol(failure) }
        guard generation == currentGeneration(), hasProcess(), !isShuttingDown else { return }
        let close = prepareClose()
        await teardownTransport()
        guard generation == currentGeneration() else { return }
        finishClose(close)
    }

    public func writeLine(
        _ data: Data, shutdownOnFailure: Bool,
        hasProcess: () -> Bool, generation: () -> UInt64,
        write: (Data) throws -> Void, scheduleShutdown: (UInt64) -> Void
    ) throws {
        guard hasProcess() else { throw ClaudeNativeClientError.processNotRunning }
        let capturedGeneration = generation()
        do { try write(data) }
        catch {
            if shutdownOnFailure { scheduleShutdown(capturedGeneration) }
            throw error
        }
    }

    public func shutdownAfterWriteFailure(
        generation: UInt64, currentGeneration: () -> UInt64,
        hasProcess: () -> Bool, shutdown: () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async {
        guard generation == currentGeneration(), hasProcess() else { return }
        await shutdown()
    }
}
