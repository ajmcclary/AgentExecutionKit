//
//  CLIProcessRunnerLaunchPrepTests.swift
//  RepoPromptTests
//
//  Characterization tests for the launch-preparation helpers extracted from
//  AgentCLIRunner.run / .runStreaming (C5). The redaction helper is
//  security-sensitive and now single-sourced, so it is pinned explicitly.
//

import XCTest
import AgentCLIExecution

final class CLIProcessRunnerLaunchPrepTests: XCTestCase {

	// MARK: redaction (security-sensitive; single-sourced)

	func testRedactsValueAfterSensitiveFlag() {
		let args = ["--model", "sonnet", "--system-prompt", "secret instructions", "--verbose"]
		let out = AgentCLIRunner.sanitizedLaunchArguments(args)
		XCTAssertEqual(out, ["--model", "sonnet", "--system-prompt", "<redacted>", "--verbose"])
	}

	func testRedactsAppendSystemPromptAndPromptValues() {
		XCTAssertEqual(
			AgentCLIRunner.sanitizedLaunchArguments(["--append-system-prompt", "x"]),
			["--append-system-prompt", "<redacted>"])
		XCTAssertEqual(
			AgentCLIRunner.sanitizedLaunchArguments(["--prompt", "y"]),
			["--prompt", "<redacted>"])
	}

	func testRedactsArgsWithStructuredMarkersNewlinesOrLength() {
		let long = String(repeating: "a", count: 121)
		let args = ["<file_map>abc", "line1\nline2", long, "<metadata>z", "ok"]
		let out = AgentCLIRunner.sanitizedLaunchArguments(args)
		XCTAssertEqual(out, ["<redacted>", "<redacted>", "<redacted>", "<redacted>", "ok"])
	}

	func testDoesNotRedactShortPlainArgs() {
		let args = ["--model", "sonnet", "--max-turns", "5"]
		XCTAssertEqual(AgentCLIRunner.sanitizedLaunchArguments(args), args)
	}

	func testFirstArgNeverRedactedBySensitiveFlagRule() {
		// index 0 has no predecessor flag, so the sensitive-flag rule cannot apply to it.
		let out = AgentCLIRunner.sanitizedLaunchArguments(["--system-prompt"])
		XCTAssertEqual(out, ["--system-prompt"])
	}

	// MARK: output-mode flag application

	func testAutoAppendsFormatTokensWhenAbsent() {
		var args = ["--model", "sonnet"]
		AgentCLIRunner.applyOutputMode(&args, outputMode: .auto(.json))
		XCTAssertEqual(args, ["--model", "sonnet", "--output-format", "json"])
	}

	func testAutoOverridesExistingOutputFormatValue() {
		var args = ["--output-format", "text", "--model", "sonnet"]
		AgentCLIRunner.applyOutputMode(&args, outputMode: .auto(.json))
		XCTAssertEqual(args, ["--output-format", "json", "--model", "sonnet"])
	}

	func testAutoAppendsFormatValueWhenFlagIsLastArg() {
		var args = ["--model", "sonnet", "--output-format"]
		AgentCLIRunner.applyOutputMode(&args, outputMode: .auto(.streamJson))
		XCTAssertEqual(args, ["--model", "sonnet", "--output-format", "stream-json"])
	}

	func testNoneLeavesArgsUnchanged() {
		var args = ["--model", "sonnet"]
		AgentCLIRunner.applyOutputMode(&args, outputMode: .none)
		XCTAssertEqual(args, ["--model", "sonnet"])
	}

	func testCustomAppendsTokens() {
		var args = ["--model", "sonnet"]
		AgentCLIRunner.applyOutputMode(&args, outputMode: .custom(["--foo", "bar"]))
		XCTAssertEqual(args, ["--model", "sonnet", "--foo", "bar"])
	}
}
