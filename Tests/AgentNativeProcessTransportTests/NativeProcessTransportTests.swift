import XCTest
import Foundation
import Synchronization
import ProcessKit
import AgentNativeProcessTransport

final class NativeProcessTransportTests: XCTestCase {
    private actor Probe {
        var waits = 0; var directReaps = 0; var finishedReaps = 0; var exited: [UInt64] = []
        var data = Data(); var stderr = Data()
        func wait(_ pid: Int32) async -> (exitCode: Int32, timedOut: Bool)? {
            waits += 1; return try? await ProcessTermination.waitForTermination(pid: pid, timeout: nil)
        }
        func reap(_ pid: Int32) async {
            directReaps += 1
            _ = await ProcessTermination.terminateAndReap(pid: pid, policy: .init(cooperativeWaitTimeout: .milliseconds(50), sigtermGracePeriod: .milliseconds(50), sigkillGracePeriod: .milliseconds(50)))
            finishedReaps += 1
        }
        func exit(_ generation: UInt64) { exited.append(generation) }
        func stdout(_ bytes: Data) { data.append(bytes) }
        func err(_ bytes: Data) { stderr.append(bytes) }
    }
    private func transport(_ probe: Probe, failStderr: Bool = false) -> AgentNativeProcessTransport {
        .init(lifecycle: .init(readPreflight: { _, label in if failStderr && label == "fixture stderr" { throw FixtureError.preflight } },
                             waitForTermination: { await probe.wait($0) }, terminateAndReap: { await probe.reap($0) }))
    }
    private enum FixtureError: Error { case preflight }
    private func spec(_ args: [String] = ["-c", "sleep 30"]) -> AgentNativeProcessTransport.LaunchSpec {
        .init(command: "/bin/sh", arguments: args, environment: [:], workingDirectory: "/tmp")
    }
    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Fixture condition did not complete"); throw FixtureError.preflight
    }
    func testUnavailableOperationsThrowWithoutSpawning() {
        let probe = Probe(); let t = transport(probe)
        XCTAssertThrowsError(try t.writeFrame(Data()))
        XCTAssertThrowsError(try t.startWaiter { _, _, _ in })
        XCTAssertThrowsError(try t.startReaders(stdoutLabel: "fixture stdout", stderrLabel: "fixture stderr", onStdout: { _, _ in }, onStderr: { _, _ in }))
        XCTAssertNil(t.invalidate()); XCTAssertFalse(t.hasProcess); XCTAssertFalse(t.hasWaiter)
    }
    func testDoubleSpawnIsRejectedAndPreWaiterLeaseReapsOnce() async throws {
        let probe = Probe(); let t = transport(probe)
        try t.spawn(spec())
        XCTAssertThrowsError(try t.spawn(spec()))
        let lease = try XCTUnwrap(t.invalidate()); XCTAssertFalse(t.hasProcess)
        await lease.finish(); await lease.finish()
        let count = await probe.directReaps; XCTAssertEqual(count, 1)
    }
    func testConcurrentLeaseFinishSharesOneReapAndCompletion() async throws {
        let probe = Probe(); let t = transport(probe); try t.spawn(spec())
        let lease = try XCTUnwrap(t.invalidate())
        await withTaskGroup(of: Void.self) { group in for _ in 0..<20 { group.addTask { await lease.finish() } } }
        let count = await probe.directReaps; XCTAssertEqual(count, 1)
    }
    func testReaderFailureUsesDirectReapBeforeWaiter() async throws {
        let probe = Probe(); let t = transport(probe, failStderr: true); try t.spawn(spec())
        XCTAssertThrowsError(try t.startReaders(stdoutLabel: "fixture stdout", stderrLabel: "fixture stderr", onStdout: { _, _ in }, onStderr: { _, _ in }))
        XCTAssertFalse(t.hasWaiter); await t.invalidate()?.finish()
        let direct = await probe.directReaps; let waits = await probe.waits
        XCTAssertEqual(direct, 1); XCTAssertEqual(waits, 0)
    }
    func testShutdownAfterWaiterInstallationNeverDirectReaps() async throws {
        let probe = Probe(); let t = transport(probe); try t.spawn(spec())
        try t.startWaiter { generation, _, _ in await probe.exit(generation) }
        XCTAssertThrowsError(try t.startWaiter { _, _, _ in })
        let lease = try XCTUnwrap(t.invalidate()); await lease.finish()
        let waits = await probe.waits; let direct = await probe.directReaps
        XCTAssertEqual(waits, 1); XCTAssertEqual(direct, 0); XCTAssertFalse(t.hasWaiter)
    }
    func testNaturalExitReleasePreventsSecondReap() async throws {
        let probe = Probe(); let t = transport(probe); try t.spawn(spec(["-c", "exit 7"]))
        let generation = t.generation
        try t.startWaiter { generation, code, timeout in
            XCTAssertEqual(code, 7); XCTAssertFalse(timeout); await probe.exit(generation)
        }
        try await waitUntil { await probe.exited.count == 1 }
        XCTAssertTrue(t.observeExit(expectedGeneration: generation)); XCTAssertNil(t.invalidate())
        XCTAssertFalse(t.hasProcess); XCTAssertFalse(t.hasWaiter)
        let direct = await probe.directReaps; XCTAssertEqual(direct, 0)
    }
    func testOldGenerationCannotInvalidateOrWriteToReplacement() async throws {
        let probe = Probe(); let t = transport(probe); try t.spawn(spec())
        let oldGeneration = t.generation; let oldLease = try XCTUnwrap(t.invalidate())
        try t.spawn(spec()); let newGeneration = t.generation
        XCTAssertNotEqual(oldGeneration, newGeneration)
        XCTAssertFalse(t.observeExit(expectedGeneration: oldGeneration)); XCTAssertNil(t.invalidate(expectedGeneration: oldGeneration))
        XCTAssertThrowsError(try t.writeFrame(Data(), expectedGeneration: oldGeneration))
        await oldLease.finish(); XCTAssertTrue(t.hasProcess)
        await t.invalidate()?.finish()
        let count = await probe.directReaps; XCTAssertEqual(count, 2)
    }
    func testExplicitLaunchEnvironmentDirectoryAndOrderedBytes() async throws {
        let probe = Probe(); let t = transport(probe)
        try t.spawn(.init(command: "/bin/sh", arguments: ["-c", "printf '%s:%s' \"$FIXTURE\" \"$PWD\"; cat; printf err >&2; sleep 30"], environment: ["FIXTURE":"explicit"], workingDirectory: "/"))
        try t.startReaders(stdoutLabel: "fixture stdout", stderrLabel: "fixture stderr",
                           onStdout: { _, data in await probe.stdout(data) }, onStderr: { _, data in await probe.err(data) })
        try t.startWaiter { generation, _, _ in await probe.exit(generation) }
        try t.writeFrame(Data("one\ntwo\n".utf8))
        try await waitUntil { await probe.data.contains(Data("two\n".utf8)) }
        let data = await probe.data
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("explicit:/"), String(decoding: data, as: UTF8.self))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("one\ntwo\n"))
        await t.invalidate()?.finish()
    }
    func testDroppedOwnerAndUnusedLeaseStillCleanTheirChildren() async throws {
        let probe = Probe()
        var owner: AgentNativeProcessTransport? = transport(probe)
        try owner?.spawn(spec())
        owner = nil
        try await waitUntil { await probe.finishedReaps == 1 }
        let second = transport(probe); try second.spawn(spec())
        _ = second.invalidate()
        try await waitUntil { await probe.finishedReaps == 2 }
    }
    func testStderrIsDeliveredSeparatelyFromStdout() async throws {
        let probe = Probe(); let t = transport(probe)
        try t.spawn(spec(["-c", "printf out; printf err >&2; sleep 30"]))
        try t.startReaders(stdoutLabel: "fixture stdout", stderrLabel: "fixture stderr",
                           onStdout: { _, data in await probe.stdout(data) }, onStderr: { _, data in await probe.err(data) })
        try await waitUntil {
            let out = await probe.data; let err = await probe.stderr
            return out == Data("out".utf8) && err == Data("err".utf8)
        }
        await t.invalidate()?.finish()
    }

}
