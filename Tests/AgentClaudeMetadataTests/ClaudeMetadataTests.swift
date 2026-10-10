import XCTest
import AgentClaudeProtocol
import AgentClaudeEvents
import AgentClaudeMetadata

final class ClaudeMetadataTests: XCTestCase {
	private func object(_ value: [String: Any]) throws -> ClaudeProtocolJSONObject { try .init(object: value) }
	private func system(_ tools: [String] = ["Bash"], name: String = "server", status: String = "connected") throws -> ClaudeProtocolJSONObject {
		try object(["type": "system", "subtype": "init", "tools": tools, "mcp_servers": [["name": name, "status": status]]])
	}
	func testInitializeSnapshotCapturesAllExistingFields() throws {
		let value = try object(["commands": [["name": "/commit", "description": "Create a commit", "argumentHint": "message"]],
			"agents": [["name": "review", "description": "Reviews code", "model": "model"]],
			"output_style": "concise", "available_output_styles": ["concise", "verbose"],
			"account": ["email": "user@example.com", "organization": "Acme", "subscriptionType": "pro", "tokenSource": "cli", "apiKeySource": "env", "apiProvider": "provider"],
			"pid": 12345, "models": [["id": "m"]], "fast_mode_state": ["enabled": true]])
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(value)
		XCTAssertEqual(parsed.commands.first?.argumentHint, "message"); XCTAssertEqual(parsed.agents.first?.model, "model")
		XCTAssertEqual(parsed.outputStyle, "concise"); XCTAssertEqual(parsed.availableOutputStyles, ["concise", "verbose"])
		XCTAssertEqual(parsed.account?.email, "user@example.com"); XCTAssertEqual(parsed.account?.organization, "Acme")
		XCTAssertEqual(parsed.account?.subscriptionType, "pro"); XCTAssertEqual(parsed.account?.tokenSource, "cli")
		XCTAssertEqual(parsed.account?.apiKeySource, "env"); XCTAssertEqual(parsed.account?.apiProvider, "provider")
		XCTAssertEqual(parsed.pid, 12345); XCTAssertNotNil(parsed.modelsJSON); XCTAssertEqual(parsed.fastModeStateJSON, "{\"enabled\":true}")
	}
	func testMissingInitializeFieldsRemainNilOrEmpty() throws {
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(object([:]))
		XCTAssertTrue(parsed.commands.isEmpty); XCTAssertTrue(parsed.agents.isEmpty)
		XCTAssertNil(parsed.outputStyle); XCTAssertTrue(parsed.availableOutputStyles.isEmpty)
		XCTAssertNil(parsed.account); XCTAssertNil(parsed.pid); XCTAssertNil(parsed.modelsJSON); XCTAssertNil(parsed.fastModeStateJSON)
	}
	func testMalformedEntriesAreSkippedWithoutTrimmingValidNames() throws {
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(object([
			"commands": [["name": " /help ", "argument_hint": "ignored"], ["description": "missing"], ["name": ""], ["name": 7]],
			"agents": [["name": "valid"], ["name": ""], ["description": "missing"]]]))
		XCTAssertEqual(parsed.commands.map(\.name), [" /help "]); XCTAssertEqual(parsed.commands.first?.argumentHint, "")
		XCTAssertEqual(parsed.agents.map(\.name), ["valid"])
	}
	func testMixedArrayKeepsLegacyAllOrNothingCast() throws {
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(object(["commands": [["name": "valid"], "bad"], "available_output_styles": ["valid", 7]]))
		XCTAssertTrue(parsed.commands.isEmpty); XCTAssertTrue(parsed.availableOutputStyles.isEmpty)
	}
	func testCanonicalJSONPreservesFragmentsOrderingNullAndLargeIntegers() throws {
		let parsed = try ClaudeMetadataCodec.parseInitializeResponse(.init(data: Data(#"{"models":{"z":9007199254740993,"a":true},"fast_mode_state":false}"#.utf8)))
		XCTAssertEqual(parsed.modelsJSON, "{\"a\":true,\"z\":9007199254740993}"); XCTAssertEqual(parsed.fastModeStateJSON, "false")
		XCTAssertNil(try ClaudeMetadataCodec.parseInitializeResponse(object(["models": NSNull()])).modelsJSON)
	}
	func testSystemInitDetectionPreservesCaseAndWhitespaceRules() throws {
		for subtype in ["init", "INIT"] {
			XCTAssertNotNil(try ClaudeMetadataCodec.parseSystemInit(object(["type": "system", "subtype": subtype])))
		}
		for (type, subtype) in [("System", "init"), ("system", " init "), ("result", "init")] {
			XCTAssertNil(try ClaudeMetadataCodec.parseSystemInit(object(["type": type, "subtype": subtype])))
		}
	}
	func testSystemInitServerNamesAndStatusesRetainRawSpellingAndLastDuplicate() throws {
		let fields = try XCTUnwrap(ClaudeMetadataCodec.parseSystemInit(object(["type": "system", "subtype": "init",
			"tools": ["Bash", "Bash", " future "], "mcp_servers": [["name": " raw ", "status": "Connected"], ["name": ""], ["name": " \n"], ["name": "s", "status": "first"], ["name": "s", "status": "last"], ["name": "empty"]]])))
		XCTAssertEqual(fields.tools, ["Bash", "Bash", " future "]); XCTAssertEqual(fields.mcpStatuses, [" raw ": "Connected", "s": "last", "empty": ""])
	}
	func testSessionIdentifierAliasPriorityPreservesBlankFirstValue() throws {
		XCTAssertEqual(try ClaudeMetadataCodec.firstSessionIdentifier(object(["session_id": " ", "sessionId": "fallback"])), " ")
		XCTAssertEqual(try ClaudeMetadataCodec.firstSessionIdentifier(object(["session_id": 4, "sessionId": "fallback"])), "fallback")
	}
	func testSessionIdentityNormalizesAndPublishesOnlyOnChange() {
		let owner = ClaudeRuntimeMetadata(); var values: [ClaudeRuntimeInitStatus] = []
		for id in [nil, " ", " raw ", "raw", "next"] as [String?] { owner.recordSessionID(id) { values.append($0) } }
		XCTAssertEqual(values.map(\.sessionID), ["raw", "next"]); XCTAssertEqual(owner.sessionID, "next")
	}
	func testInitializeIdentityPublicationPrecedesStoredSnapshotUntilReadiness() throws {
		let owner = ClaudeRuntimeMetadata(); var values: [ClaudeRuntimeInitStatus] = []
		let parsed = try owner.recordInitialize(object(["session_id": " raw ", "commands": [["name": "help"]]])) { values.append($0) }
		XCTAssertEqual(parsed?.commands.first?.name, "help"); XCTAssertEqual(values.count, 1); XCTAssertNil(values[0].initializeResponse)
		owner.publishIfChanged { values.append($0) }
		XCTAssertEqual(values.count, 2); XCTAssertEqual(values[1].initializeResponse?.commands.first?.name, "help")
	}
	func testSystemMetadataReplacesRatherThanAccumulatesAndObservesBeforePublication() throws {
		let owner = ClaudeRuntimeMetadata(); var order: [String] = []
		try owner.recordSystemInit(system(), observe: { _ in order.append("observe") }, emit: { _ in order.append("publish") })
		try owner.recordSystemInit(system(["Write"], name: "other"), observe: { _ in }, emit: { _ in })
		XCTAssertEqual(order, ["observe", "publish"]); XCTAssertEqual(owner.snapshot.tools, ["Write"])
		XCTAssertEqual(owner.snapshot.mcpServerStatuses, ["other": "connected"])
	}
	func testRepeatedMetadataIsDeduplicatedButDistinctFieldsPublish() throws {
		let owner = ClaudeRuntimeMetadata(); var count = 0
		for _ in 0..<2 { try owner.recordSystemInit(system(), observe: { _ in }, emit: { _ in count += 1 }) }
		try owner.recordSystemInit(system(status: "failed"), observe: { _ in }, emit: { _ in count += 1 })
		XCTAssertEqual(count, 2)
	}
	func testResetRetainsSessionIdentityAndAllowsFreshIdenticalPublication() throws {
		let owner = ClaudeRuntimeMetadata(); owner.recordSessionID("id") { _ in }
		try owner.recordSystemInit(system(), observe: { _ in }, emit: { _ in }); owner.resetObservations()
		XCTAssertEqual(owner.sessionID, "id"); XCTAssertTrue(owner.snapshot.tools.isEmpty); XCTAssertNil(owner.snapshot.initializeResponse)
		var count = 0; owner.publishIfChanged { _ in count += 1 }; owner.publishIfChanged { _ in count += 1 }
		XCTAssertEqual(count, 1)
	}
	func testRetiredObservationTokensCannotChangeNewMetadata() throws {
		let owner = ClaudeRuntimeMetadata(); let old = owner.token; owner.resetObservations()
		owner.recordSessionID("old", for: old) { _ in XCTFail("Retired") }
		XCTAssertNil(try owner.recordInitialize(object(["session_id": "old"]), for: old) { _ in XCTFail("Retired") })
		XCTAssertFalse(try owner.recordSystemInit(system(), for: old, observe: { _ in XCTFail("Retired") }, emit: { _ in XCTFail("Retired") }))
		XCTAssertNil(owner.sessionID)
	}
	func testReentrantIdenticalPublishCannotDuplicate() {
		let owner = ClaudeRuntimeMetadata(); var count = 0
		owner.publishIfChanged { _ in count += 1; owner.publishIfChanged { _ in XCTFail("Duplicate") } }
		XCTAssertEqual(count, 1)
	}
	func testReentrantResetDuringSystemObservationPreventsOldPublication() throws {
		let owner = ClaudeRuntimeMetadata()
		XCTAssertFalse(try owner.recordSystemInit(system(), observe: { _ in owner.resetObservations() }, emit: { _ in XCTFail("Replaced") }))
		XCTAssertTrue(owner.snapshot.tools.isEmpty)
	}
	func testReentrantResetDuringIdentityPublicationCannotStoreOldInitializeSnapshot() throws {
		let owner = ClaudeRuntimeMetadata()
		XCTAssertNil(try owner.recordInitialize(object(["session_id": "id", "commands": [["name": "old"]]])) { _ in owner.resetObservations() })
		XCTAssertNil(owner.snapshot.initializeResponse)
	}
	func testServerPolicyUsesExplicitIdentityAndExistingFailureNormalization() {
		let value = ClaudeRuntimeInitStatus(sessionID: nil, tools: [], mcpServerStatuses: ["HOST": " Failed \n", "other": "connected"], initializeResponse: nil)
		XCTAssertTrue(value.isServerFailed(named: "host")); XCTAssertFalse(value.isServerFailed(named: "other")); XCTAssertNil(value.serverStatus(named: "missing"))
	}
	func testParseInitializeResponseSnapshotCapturesAllFields() throws {
		let response: [String: Any] = [
			"commands": [
				["name": "/help", "description": "Show help", "argumentHint": ""],
				["name": "/commit", "description": "Create a commit", "argumentHint": "message"]
			],
			"agents": [
				["name": "code-review", "description": "Reviews code changes", "model": "claude-sonnet-4-5-20250514"],
				["name": "pair", "description": "Pair programming"]
			],
			"output_style": "concise",
			"available_output_styles": ["concise", "verbose", "minimal"],
			"account": [
				"email": "user@example.com",
				"organization": "Acme",
				"subscriptionType": "pro",
				"tokenSource": "anthropic",
				"apiKeySource": "env",
				"apiProvider": "firstParty"
			],
			"pid": 12345,
			"models": [["id": "claude-opus-4-6", "name": "Opus"]],
			"fast_mode_state": ["enabled": true]
		]

		let snapshot = try ClaudeMetadataCodec.parseInitializeResponse(object(response))

		XCTAssertEqual(snapshot.commands.count, 2)
		XCTAssertEqual(snapshot.commands[0].name, "/help")
		XCTAssertEqual(snapshot.commands[1].name, "/commit")
		XCTAssertEqual(snapshot.commands[1].argumentHint, "message")

		XCTAssertEqual(snapshot.agents.count, 2)
		XCTAssertEqual(snapshot.agents[0].name, "code-review")
		XCTAssertEqual(snapshot.agents[0].model, "claude-sonnet-4-5-20250514")
		XCTAssertEqual(snapshot.agents[1].name, "pair")
		XCTAssertNil(snapshot.agents[1].model)

		XCTAssertEqual(snapshot.outputStyle, "concise")
		XCTAssertEqual(snapshot.availableOutputStyles, ["concise", "verbose", "minimal"])

		XCTAssertEqual(snapshot.account?.email, "user@example.com")
		XCTAssertEqual(snapshot.account?.organization, "Acme")
		XCTAssertEqual(snapshot.account?.subscriptionType, "pro")
		XCTAssertEqual(snapshot.account?.tokenSource, "anthropic")
		XCTAssertEqual(snapshot.account?.apiKeySource, "env")
		XCTAssertEqual(snapshot.account?.apiProvider, "firstParty")

		XCTAssertEqual(snapshot.pid, 12345)
		XCTAssertNotNil(snapshot.modelsJSON)
		XCTAssertNotNil(snapshot.fastModeStateJSON)
	}

	func testParseInitializeResponseSnapshotToleratsMissingFields() throws {
		let snapshot = try ClaudeMetadataCodec.parseInitializeResponse(object([:]))

		XCTAssertTrue(snapshot.commands.isEmpty)
		XCTAssertTrue(snapshot.agents.isEmpty)
		XCTAssertNil(snapshot.outputStyle)
		XCTAssertTrue(snapshot.availableOutputStyles.isEmpty)
		XCTAssertNil(snapshot.account)
		XCTAssertNil(snapshot.pid)
		XCTAssertNil(snapshot.modelsJSON)
		XCTAssertNil(snapshot.fastModeStateJSON)
	}

	func testParseInitializeResponseSnapshotSkipsMalformedEntries() throws {
		let response: [String: Any] = [
			"commands": [
				["name": "/help", "description": "Show help", "argumentHint": ""],
				["description": "Missing name"],  // no name, should be skipped
				["name": "", "description": "Empty name"]  // empty name, should be skipped
			],
			"agents": [
				["name": "valid", "description": "Valid agent"],
				["description": "Missing name agent"]  // should be skipped
			]
		]

		let snapshot = try ClaudeMetadataCodec.parseInitializeResponse(object(response))
		XCTAssertEqual(snapshot.commands.count, 1)
		XCTAssertEqual(snapshot.commands[0].name, "/help")
		XCTAssertEqual(snapshot.agents.count, 1)
		XCTAssertEqual(snapshot.agents[0].name, "valid")
	}
}
