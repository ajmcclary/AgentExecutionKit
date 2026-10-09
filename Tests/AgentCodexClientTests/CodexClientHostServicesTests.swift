import XCTest
import Foundation
import Synchronization
import AgentCodexClient
import CodexRuntimeKit
import ProcessKit

final class CodexClientHostServicesTests: XCTestCase {
	private final class RecordedValues<Value: Sendable>: Sendable {
		let storage = Mutex<[Value]>([])
	}
	private func waitUntil(_ condition: () async -> Bool) async -> Bool {
		for _ in 0..<200 {
			if await condition() { return true }
			try? await Task.sleep(for: .milliseconds(10))
		}
		return false
	}

	private actor LaunchGate {
		var entered = false
		var waiter: CheckedContinuation<Void, Never>?
		func suspend() async {
			entered = true
			await withCheckedContinuation { waiter = $0 }
		}
		func release() { waiter?.resume(); waiter = nil }
	}

	private func makeScript() throws -> URL {
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let script = directory.appendingPathComponent("fixture-codex")
		try #"""
		#!/bin/sh
		while IFS= read -r line; do
		  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
		  if [ -n "$id" ]; then printf '{"id":%s,"result":{}}\n' "$id"; fi
		done
		"""#.write(to: script, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
		return script
	}

	private func host(
		identity: CodexAgentClient.ClientIdentity = .init(name: "test-host", title: "Test Host", version: "27"),
		prepare: @escaping @Sendable (CodexAgentClient.Config) async throws -> CodexAgentClient.LaunchSpecification
	) -> CodexAgentClient.HostServices {
		.init(clientIdentity: identity, prepareLaunch: prepare,
			  terminationPolicy: CodexTestHost.host.terminationPolicy,
			  diagnostics: { _ in }, readErrorCode: { ($0 as? POSIXError)?.code.rawValue })
	}

	private func client(host: CodexAgentClient.HostServices, frames: RecordedValues<Data>) -> CodexAgentClient {
		CodexAgentClient(configuration: .init(commandName: "injected-only", additionalPathHints: [], requestTimeout: 2), host: host,
			writeFrameHandler: { fd, frame in
				frames.storage.withLock { $0.append(frame) }
				try FDWriteSupport.writeAll(frame, to: fd)
			}, expectedAgentPIDRegistrar: .init(register: { _, _, _ in }, clear: { _, _, _ in }),
			readPreflight: CodexTestHost.validateFD)
	}

	func testInitializationUsesHostIdentityAndStableAdmissionOmitsCapabilities() async throws {
		let script = try makeScript()
		defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
		let frames = RecordedValues<Data>()
		let client = client(host: host { config in
			.init(command: script.path, arguments: [], environment: [:], workingDirectory: config.workingDirectory)
		}, frames: frames)
		try await client.startIfNeeded()
		await client.stop()
		let first = try XCTUnwrap(frames.storage.withLock { $0.first })
		let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
		let params = try XCTUnwrap(payload["params"] as? [String: Any])
		let info = try XCTUnwrap(params["clientInfo"] as? [String: String])
		XCTAssertEqual(info, ["name": "test-host", "title": "Test Host", "version": "27"])
		XCTAssertNil(params["capabilities"])
	}

	func testStoppingWhileHostLaunchPreparationIsSuspendedDoesNotSpawn() async throws {
		let gate = LaunchGate()
		let frames = RecordedValues<Data>()
		let client = client(host: host { _ in
			await gate.suspend()
			return .init(command: "/bin/cat", arguments: [], environment: [:], workingDirectory: nil)
		}, frames: frames)
		let startup = Task { try await client.startIfNeeded() }
		let entered = await waitUntil { await gate.entered }
		XCTAssertTrue(entered)
		await client.stop()
		await gate.release()
		do { try await startup.value; XCTFail("Stopped startup must throw cancellation") }
		catch is CancellationError {}
		let running = await client.debugIsProcessRunning()
		XCTAssertFalse(running)
		XCTAssertTrue(frames.storage.withLock { $0.isEmpty })
	}

	func testConfigurationChangedDuringPreparationIsResolvedAgainBeforeAdmissionFreeze() async throws {
		let script = try makeScript()
		defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
		let gate = LaunchGate()
		let snapshots = RecordedValues<CodexAgentClient.Config>()
		let frames = RecordedValues<Data>()
		let client = client(host: host { config in
			let count = snapshots.storage.withLock { $0.append(config); return $0.count }
			if count == 1 { await gate.suspend() }
			return .init(command: script.path, arguments: [], environment: config.environmentOverrides, workingDirectory: nil)
		}, frames: frames)
		let startup = Task { try await client.startIfNeeded() }
		let entered = await waitUntil { await gate.entered }
		XCTAssertTrue(entered)
		await client.updateExperimentalRequirements([.memoryMode], reason: "updated while resolving")
		await gate.release()
		try await startup.value
		let admission = await client.currentExperimentalAdmission()
		await client.stop()
		XCTAssertEqual(snapshots.storage.withLock { $0.map(\.experimentalRequirements) }, [[], [.memoryMode]])
		XCTAssertEqual(admission?.requirements, [.memoryMode])
		let first = try XCTUnwrap(frames.storage.withLock { $0.first })
		let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
		let params = try XCTUnwrap(payload["params"] as? [String: Any])
		XCTAssertEqual((params["capabilities"] as? [String: Bool])?["experimentalApi"], true)
	}

	func testOldGenerationStdoutCannotReachNewSubscribers() async throws {
		let client = CodexAgentClient(writeFrameHandler: { _, _ in })
		await client.debugInstallTestTransport()
		let oldGeneration = await client.debugTransportGeneration()
		await client.stop()
		await client.debugInstallTestTransport()
		let currentGeneration = await client.debugTransportGeneration()
		let stream = await client.subscribeNotifications()
		await client.debugIngestStdoutChunk(Data("{\"method\":\"stale\",\"params\":{}}\n".utf8), generation: oldGeneration)
		await client.debugIngestStdoutChunk(Data("{\"method\":\"current\",\"params\":{}}\n".utf8), generation: currentGeneration)
		await client.stop()
		var methods: [String] = []
		for await notification in stream { methods.append(notification.method) }
		XCTAssertEqual(methods, ["current"])
	}

	func testSendableJSONRequestCancellationAndLateResponseDoNotPoisonClient() async throws {
		let frames = RecordedValues<Data>()
		let client = CodexAgentClient(writeFrameHandler: { _, frame in frames.storage.withLock { $0.append(frame) } })
		await client.debugInstallTestTransport()
		let provider: any CodexAgentClientProviding = client
		let request = Task {
			try await provider.requestJSON(method: "model/list", params: ["nested": .array([.string("value"), .null])], timeout: 2)
		}
		let registered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(registered)
		request.cancel()
		do { _ = try await request.value; XCTFail("Cancelled request must fail") }
		catch is CancellationError {}
		await client.debugIngestRawStdoutLine(Data(#"{"id":1,"result":{"late":true}}"#.utf8))
		let pending = await client.debugPendingRequestCount()
		let alive = await client.debugIsProcessRunning()
		await client.stop()
		XCTAssertEqual(pending, 0)
		XCTAssertTrue(alive)
		let first = try XCTUnwrap(frames.storage.withLock { $0.first })
		let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
		XCTAssertEqual(((payload["params"] as? [String: Any])?["nested"] as? [Any])?.count, 2)
	}

	func testModelPaginationKeepsSparseUnknownModelsAndUpgradeMetadata() async throws {
		let client = CodexAgentClient(writeFrameHandler: { _, _ in }, livenessProbe: { _ in true })
		await client.debugInstallTestTransport()
		let listing = Task { try await client.listModels(limit: 0) }
		let firstRegistered = await waitUntil { await client.debugPendingRequestCount() == 1 }
		XCTAssertTrue(firstRegistered)
		await client.debugIngestRawStdoutLine(Data(#"{"id":1,"result":{"data":[{"id":"unknown"},{"id":"known","model":"canonical","supportedReasoningEfforts":[{"reasoningEffort":" ","description":"skip"},{"reasoningEffort":"high","description":"High"}],"upgrade":"successor","upgradeInfo":{"model":" next ","modelLink":"https://example.invalid/model"},"serviceTiers":[{"id":"fast"},{"id":""}]}],"nextCursor":"page2"}}"#.utf8))
		let secondRegistered = await waitUntil { await client.debugNextRequestID() == 3 }
		XCTAssertTrue(secondRegistered)
		await client.debugIngestRawStdoutLine(Data(#"{"id":2,"result":{"data":[{"id":"known"},{"id":"later"},{"id":""}],"nextCursor":"page2"}}"#.utf8))
		let models = try await listing.value
		await client.stop()
		XCTAssertEqual(models.map(\.id), ["unknown", "known", "later"])
		XCTAssertEqual(models[0].displayName, "unknown")
		XCTAssertEqual(models[1].supportedReasoningEfforts.map(\.reasoningEffort), ["high"])
		XCTAssertEqual(models[1].serviceTierIDs, ["fast"])
		XCTAssertEqual(models[1].upgradeInfo?.model, "next")
		XCTAssertEqual(models[1].upgradeModelID, "successor")
	}
}
