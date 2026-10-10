import XCTest
import Foundation
import AgentClaudeProtocol
import AgentClaudeSession

@MainActor
final class ClaudeSessionInitializationTests: XCTestCase {
	enum Failure: Error, Equatable { case rpc, permission, admission, retired }
	actor Gate<Value: Sendable> {
		private var waiters: [CheckedContinuation<Value, any Error>] = []
		var count: Int { waiters.count }
		func wait() async throws -> Value { try await withCheckedThrowingContinuation { waiters.append($0) } }
		func send(_ value: Value) { waiters.removeFirst().resume(returning: value) }
	}
	@MainActor final class Host {
		let owner = ClaudeSessionInitialization(retiredError: { Failure.retired })
		var available = true
		var calls: [(String, TimeInterval?)] = []
		var order: [String] = []
		func rpc(_ request: ClaudeProtocolJSONObject, _ timeout: TimeInterval?) throws -> ClaudeProtocolJSONObject {
			let kind = try request.dictionary()["subtype"] as? String ?? "unknown"
			calls.append((kind, timeout)); order.append("rpc:\(kind)"); return try .init(object: ["ack": kind])
		}
		func observe(_ event: ClaudeSessionInitialization.Event) {
			switch event {
			case .pending: order.append("pending")
			case .applied(_, _, .initialization): order.append("initial-settings")
			case .applied(_, _, .liveUpdate): order.append("live-settings")
			}
		}
	}
	private func settings(_ name: String) throws -> ClaudeProtocolJSONObject {
		try .init(object: ["subtype": name, "settings": ["model": name]])
	}
	private func wait(_ condition: () async -> Bool) async {
		for _ in 0..<10_000 { if await condition() { return }; await Task.yield() }
		let ready = await condition(); XCTAssertTrue(ready, "Expected suspended operation")
	}
	private func initialize(_ host: Host, permission: (() async throws -> Void)? = nil,
		admit: ((ClaudeProtocolJSONObject) async throws -> Void)? = nil) async throws {
		try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: 60,
			rpc: { try await host.rpc($0, $1) }, onResponse: { _ in host.order.append("response") },
			observeSettings: host.observe, applyPermissionMode: permission ?? { host.order.append("permission") },
			admit: admit ?? { _ in host.order.append("admission") }, onReady: { host.order.append("ready") })
	}
	func testReadinessFollowsResponseSettingsPermissionAndAdmissionInOrder() async throws {
		let host = Host(); host.owner.storeSettings(try settings("settings"))
		try await initialize(host, permission: {
			XCTAssertTrue(host.owner.hasCompletedInitialSettings); XCTAssertFalse(host.owner.isInitialized); host.order.append("permission")
		}, admit: { _ in XCTAssertFalse(host.owner.isInitialized); host.order.append("admission") })
		XCTAssertEqual(host.order, ["rpc:initialize", "response", "rpc:settings", "initial-settings", "permission", "admission", "ready"])
		XCTAssertTrue(host.owner.isInitialized); XCTAssertEqual(host.calls[0].1, 60); XCTAssertNil(host.calls[1].1)
	}
	func testInitializedSessionDoesNotRepeatHandshakeOrHooks() async throws {
		let host = Host(); try await initialize(host); let before = host.order
		try await initialize(host); XCTAssertEqual(host.order, before)
	}
	func testNilInitialSettingsCompletesWithoutExtraRPC() async throws {
		let host = Host(); try await initialize(host)
		XCTAssertEqual(host.calls.map(\.0), ["initialize"]); XCTAssertTrue(host.owner.hasCompletedInitialSettings)
	}
	func testInitializationRPCFailureDoesNotObserveOrAdmit() async throws {
		let host = Host()
		do {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil, rpc: { _, _ in throw Failure.rpc },
				onResponse: { _ in XCTFail("No response") }, observeSettings: { _ in XCTFail("No settings") },
				applyPermissionMode: { XCTFail("No permission") }, admit: { _ in XCTFail("No admission") }, onReady: { XCTFail("No readiness") })
			XCTFail("Expected RPC failure")
		} catch { XCTAssertEqual(error as? Failure, .rpc) }
		XCTAssertFalse(host.owner.isInitialized); XCTAssertFalse(host.owner.hasCompletedInitialSettings)
	}
	func testPermissionFailureAndAdmissionRejectionNeverCommitReadiness() async throws {
		for failure in [Failure.permission, .admission] {
			let host = Host()
			do {
				try await initialize(host, permission: { if failure == .permission { throw failure } }, admit: { _ in throw failure })
				XCTFail("Expected refusal")
			} catch { XCTAssertEqual(error as? Failure, failure) }
			XCTAssertFalse(host.owner.isInitialized); XCTAssertTrue(host.owner.hasCompletedInitialSettings)
		}
	}
	func testInitialSettingsConvergeWhenUpdatedDuringSuspendedRPC() async throws {
		let host = Host(); let gate = Gate<ClaudeProtocolJSONObject>(); host.owner.storeSettings(try settings("first"))
		let task = Task {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil,
				rpc: { request, timeout in
					let kind = try await host.rpc(request, timeout)
					if try request.dictionary()["subtype"] as? String == "first" { return try await gate.wait() }
					return kind
				}, onResponse: { _ in }, observeSettings: host.observe, applyPermissionMode: {}, admit: { _ in }, onReady: {})
		}
		await wait { await gate.count == 1 }; host.owner.storeSettings(try settings("second"))
		await gate.send(try .init(object: [:])); try await task.value
		XCTAssertEqual(host.calls.map(\.0), ["initialize", "first", "second"])
		XCTAssertTrue(host.owner.isInitialized); XCTAssertTrue(host.owner.hasCompletedInitialSettings)
	}
	func testClearingSettingsDuringInitialRPCDoesNotSendAnotherRequest() async throws {
		let host = Host(); let gate = Gate<ClaudeProtocolJSONObject>(); host.owner.storeSettings(try settings("settings"))
		let task = Task {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil,
				rpc: { request, timeout in
					let value = try await host.rpc(request, timeout)
					if try request.dictionary()["subtype"] as? String == "settings" { return try await gate.wait() }; return value
				}, onResponse: { _ in }, observeSettings: host.observe, applyPermissionMode: {}, admit: { _ in }, onReady: {})
		}
		await wait { await gate.count == 1 }; host.owner.storeSettings(nil)
		await gate.send(try .init(object: [:])); try await task.value
		XCTAssertEqual(host.calls.count, 2); XCTAssertTrue(host.owner.hasCompletedInitialSettings)
	}
	func testLiveApplyBeforeInitializationStoresLatestRequestAndReportsPending() async throws {
		let host = Host()
		let outcome = try await host.owner.applyLiveSettings(resolve: { try self.settings("model") }, isProcessAvailable: { host.available },
			rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		XCTAssertEqual(outcome, .pendingInitialization); XCTAssertFalse(outcome.establishesAcceptance)
		XCTAssertEqual(try host.owner.pendingSettings?.dictionary()["subtype"] as? String, "model")
		XCTAssertTrue(host.calls.isEmpty)
	}
	func testUnavailableProcessDoesNotResolveSettings() async throws {
		let host = Host(); host.available = false
		let result = try await host.owner.applyLiveSettings(resolve: { XCTFail("Unavailable"); return nil }, isProcessAvailable: { host.available },
			rpc: { _, _ in XCTFail("Unavailable"); throw Failure.rpc }, observe: { _ in XCTFail("Unavailable") })
		XCTAssertEqual(result, .noProcess)
	}
	func testProcessLossAfterResolutionKeepsStoredSettingsButSendsNothing() async throws {
		let host = Host()
		let result = try await host.owner.applyLiveSettings(resolve: { host.available = false; return try self.settings("model") },
			isProcessAvailable: { host.available }, rpc: { _, _ in XCTFail("No process"); throw Failure.rpc }, observe: { _ in XCTFail("No process") })
		XCTAssertEqual(result, .noProcess); XCTAssertNotNil(host.owner.pendingSettings)
	}
	func testLatestIntentWinsWhileOlderResolutionIsSuspended() async throws {
		let host = Host(); let gate = Gate<ClaudeProtocolJSONObject?>()
		let old = Task { try await host.owner.applyLiveSettings(resolve: { try await gate.wait() },
			isProcessAvailable: { host.available }, rpc: { try await host.rpc($0, $1) }, observe: host.observe) }
		await wait { await gate.count == 1 }
		let newest = try await host.owner.applyLiveSettings(resolve: { try self.settings("new") }, isProcessAvailable: { host.available },
			rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		await gate.send(try settings("old")); let stale = try await old.value
		XCTAssertEqual(newest, .pendingInitialization); XCTAssertEqual(stale, .superseded)
		XCTAssertEqual(try host.owner.pendingSettings?.dictionary()["subtype"] as? String, "new")
	}
	func testReadyLiveApplyUsesFiveSecondDeadlineAndOnlyACKEstablishesAcceptance() async throws {
		let host = Host(); try await initialize(host)
		let result = try await host.owner.applyLiveSettings(resolve: { try self.settings("model") }, isProcessAvailable: { host.available },
			rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		XCTAssertEqual(result, .applied); XCTAssertTrue(result.establishesAcceptance)
		XCTAssertEqual(host.calls.last?.1, 5); XCTAssertEqual(host.order.last, "live-settings")
	}
	func testNilLiveRequestReportsNoRequestOnlyAfterInitialization() async throws {
		let host = Host(); try await initialize(host); let calls = host.calls.count
		let result = try await host.owner.applyLiveSettings(resolve: { nil }, isProcessAvailable: { true }, rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		XCTAssertEqual(result, .noRequest); XCTAssertEqual(host.calls.count, calls)
	}
	func testReadinessWindowAllowsLiveApplyAfterInitialSettingsBeforeAdmission() async throws {
		let host = Host(); let gate = Gate<Bool>()
		let task = Task { try await initialize(host, permission: { _ = try await gate.wait() }) }
		await wait { await gate.count == 1 }
		XCTAssertFalse(host.owner.isInitialized); XCTAssertTrue(host.owner.hasCompletedInitialSettings)
		let result = try await host.owner.applyLiveSettings(resolve: { try self.settings("model") }, isProcessAvailable: { true }, rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		XCTAssertEqual(result, .applied); await gate.send(true); try await task.value
	}
	func testRetiredResolutionCannotOverwriteReplacementLaunchEvenWhenCounterResets() async throws {
		let host = Host(); let gate = Gate<ClaudeProtocolJSONObject?>()
		let old = Task { try await host.owner.applyLiveSettings(resolve: { try await gate.wait() }, isProcessAvailable: { true }, rpc: { try await host.rpc($0, $1) }, observe: host.observe) }
		await wait { await gate.count == 1 }; host.owner.beginLaunch()
		_ = try await host.owner.applyLiveSettings(resolve: { try self.settings("replacement") }, isProcessAvailable: { true }, rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		await gate.send(try settings("old")); let result = try await old.value
		XCTAssertEqual(result, .superseded); XCTAssertEqual(try host.owner.pendingSettings?.dictionary()["subtype"] as? String, "replacement")
	}
	func testRetiredLiveACKCannotReportAcceptanceOrEmitObservation() async throws {
		let host = Host(); try await initialize(host); let gate = Gate<ClaudeProtocolJSONObject>()
		let task = Task { try await host.owner.applyLiveSettings(resolve: { try self.settings("model") }, isProcessAvailable: { true },
			rpc: { _, _ in try await gate.wait() }, observe: { _ in XCTFail("Retired ACK") }) }
		await wait { await gate.count == 1 }; host.owner.retire(); await gate.send(try .init(object: [:]))
		let result = try await task.value; XCTAssertEqual(result, .superseded); XCTAssertFalse(host.owner.isInitialized)
	}
	func testSameEpochACKStillEstablishesAcceptanceAfterNewerIntent() async throws {
		let host = Host(); try await initialize(host); let gate = Gate<ClaudeProtocolJSONObject>()
		let old = Task { try await host.owner.applyLiveSettings(resolve: { try self.settings("old") }, isProcessAvailable: { true }, rpc: { _, _ in try await gate.wait() }, observe: host.observe) }
		await wait { await gate.count == 1 }
		_ = try await host.owner.applyLiveSettings(resolve: { try self.settings("new") }, isProcessAvailable: { true }, rpc: { try await host.rpc($0, $1) }, observe: host.observe)
		await gate.send(try .init(object: [:])); let result = try await old.value
		XCTAssertEqual(result, .applied)
	}
	func testRetirementDuringEachSuspendedInitializationPhaseNeverCommitsReady() async throws {
		for phase in ["initialize", "settings", "permission", "admission"] {
			let host = Host(); host.owner.storeSettings(try settings("settings")); let gate = Gate<ClaudeProtocolJSONObject>()
			let task = Task {
				try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil,
					rpc: { request, timeout in
						let kind = try request.dictionary()["subtype"] as? String
						if kind == phase { return try await gate.wait() }; return try await host.rpc(request, timeout)
					}, onResponse: { _ in }, observeSettings: host.observe,
					applyPermissionMode: { if phase == "permission" { _ = try await gate.wait() } },
					admit: { _ in if phase == "admission" { _ = try await gate.wait() } }, onReady: { XCTFail("Retired readiness") })
			}
			await wait { await gate.count == 1 }; host.owner.retire(); await gate.send(try .init(object: [:]))
			do { try await task.value; XCTFail("Expected retirement") } catch { XCTAssertEqual(error as? Failure, .retired) }
			XCTAssertFalse(host.owner.isInitialized); XCTAssertFalse(host.owner.hasCompletedInitialSettings)
		}
	}
	func testReentrantResponseObservationCannotInitializeRetiredScope() async throws {
		let host = Host()
		do {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil, rpc: { try await host.rpc($0, $1) },
				onResponse: { _ in host.owner.retire() }, observeSettings: { _ in XCTFail("Retired") },
				applyPermissionMode: { XCTFail("Retired") }, admit: { _ in XCTFail("Retired") }, onReady: { XCTFail("Retired") })
			XCTFail("Expected retirement")
		} catch { XCTAssertEqual(error as? Failure, .retired) }
	}
	func testRetirementRetainsSettingsButLaunchCanReplaceThem() throws {
		let host = Host(); let value = try settings("prior"); host.owner.storeSettings(value); host.owner.retire()
		XCTAssertEqual(host.owner.pendingSettings, value); host.owner.beginLaunch(); host.owner.storeSettings(nil)
		XCTAssertNil(host.owner.pendingSettings)
	}
	func testInitialSettingsRPCFailureCannotReachPermissionOrAdmission() async throws {
		let host = Host(); host.owner.storeSettings(try settings("settings"))
		do {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil,
				rpc: { request, timeout in
					if try request.dictionary()["subtype"] as? String == "settings" { throw Failure.rpc }
					return try await host.rpc(request, timeout)
				}, onResponse: { _ in }, observeSettings: { _ in XCTFail("Failed request") },
				applyPermissionMode: { XCTFail("Failed request") }, admit: { _ in XCTFail("Failed request") }, onReady: { XCTFail("Failed request") })
			XCTFail("Expected error")
		} catch { XCTAssertEqual(error as? Failure, .rpc) }
		XCTAssertFalse(host.owner.hasCompletedInitialSettings); XCTAssertFalse(host.owner.isInitialized)
	}
	func testLiveResolutionAndRPCFailuresPreserveOriginalErrors() async throws {
		let host = Host(); try await initialize(host)
		for resolveFails in [true, false] {
			do {
				_ = try await host.owner.applyLiveSettings(resolve: {
					if resolveFails { throw Failure.rpc }; return try self.settings("model")
				}, isProcessAvailable: { true }, rpc: { _, _ in throw Failure.rpc }, observe: { _ in XCTFail("Failed apply") })
				XCTFail("Expected error")
			} catch { XCTAssertEqual(error as? Failure, .rpc) }
		}
		XCTAssertTrue(host.owner.isInitialized)
	}
	func testReadinessCallbackRetirementCannotReturnSuccessfulInitialization() async throws {
		let host = Host()
		do {
			try await host.owner.initialize(request: settings("initialize"), timeoutSeconds: nil, rpc: { try await host.rpc($0, $1) },
				onResponse: { _ in }, observeSettings: host.observe, applyPermissionMode: {}, admit: { _ in },
				onReady: { XCTAssertTrue(host.owner.isInitialized); host.owner.retire() })
			XCTFail("Expected retirement")
		} catch { XCTAssertEqual(error as? Failure, .retired) }
	}
	func testLiveObservationRetirementCannotReturnAcceptanceForAnotherScope() async throws {
		let host = Host(); try await initialize(host)
		let outcome = try await host.owner.applyLiveSettings(resolve: { try self.settings("model") }, isProcessAvailable: { true },
			rpc: { try await host.rpc($0, $1) }, observe: { _ in host.owner.retire() })
		XCTAssertEqual(outcome, .superseded); XCTAssertFalse(outcome.establishesAcceptance)
	}
	func testOnlyAppliedOutcomeEstablishesAcceptance() {
		for outcome in [ClaudeSessionInitialization.ApplyOutcome.noProcess, .superseded, .pendingInitialization, .noRequest] {
			XCTAssertFalse(outcome.establishesAcceptance)
		}
		XCTAssertTrue(ClaudeSessionInitialization.ApplyOutcome.applied.establishesAcceptance)
	}
}
