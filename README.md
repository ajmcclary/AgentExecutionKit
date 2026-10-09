# AgentExecutionKit

Shared agent execution infrastructure. The initial `AgentProcessSupport` product
owns launch-context classification, environment sanitization, and child-process
registry ownership extracted from RepoPrompt's ProcessCore. Host environment
markers are explicit inputs. There are no app/UI imports or implicit settings.

Swift 6, strict concurrency, macOS 27. Build and test with `swift build` and
`swift test`. Process primitives remain in ProcessKit. Provider protocol framing,
sessions, persistence, and MCP hosting are subsequent adoption slices.

`AgentCodexClient` owns the native Codex app-server client's single-flight startup,
experimental admission, request retry/cancellation/timeouts, notification and
server-request subscriptions, model pagination, decoder recovery, and teardown.
`CodexAgentClientProviding` exposes sendable JSON requests and provider runtime
values. Raw dictionary entry points support existing authentication/controller
adapters during adoption. External SDK types do not cross the interface.

Hosts explicitly supply client identity, launch resolution (including environment,
arguments, credentials, executable and working directory), termination policy,
PID registration, read preflight/error classification, and diagnostics. Separate
client instances own separate transports and request/subscriber state. A config
change while launch preparation is suspended triggers fresh resolution; stopped
startup and old-generation stdout cannot affect a replacement transport.

The Codex product depends on CodexRuntimeKit, CodexAppServerKit, AgentRuntimeKit,
and ProcessKit. The existing process-support product does not link the Codex target.
Portable client/transport characterizations were moved from RepoPrompt alongside
additional injected-host, cancellation, pagination and startup race tests.

Build the products independently with `swift build --target AgentProcessSupport`,
`swift build --target AgentExecutionKit`, and `swift build --target AgentCodexClient`.
Claude/ACP clients and native session controllers remain subsequent extractions.

Source lineage: RepoPrompt (`github.com/ajmcclary/RepoPrompt`), Apache-2.0.

`AgentClaudeProtocol` owns Claude native control-message decoding/encoding,
stateful two-lane event translation, provider-neutral result projection, and
lifecycle wire-fact extraction. Public control payloads use immutable JSON data
rather than sharing Foundation object graphs; unknown fields and large integers
survive. Batches retain raw evidence, compatibility results, normalized events,
and redacted diagnostics together. Tool-status ownership and logging callbacks
are host inputs. The runtime kit still owns vocabulary, lifecycle normalization,
redaction, partial input assembly, and accounting. This product links only the
core AI contracts, Claude/agent runtime values, and stream-framing primitives;
it introduces no HTTP, storage, UI, or process-spawn dependency to those kits.
Reasoning extraction follows host policy on the compatibility lane; RepoPrompt
retains its existing disabled flag and projection-authority policy.

Build this product independently with `swift build --target AgentClaudeProtocol`.
Native Claude process/session ownership and ACP clients remain later slices.

`AgentCLIExecution` owns buffered/streaming child execution, cancellable FIFO
admission, stdin feeding, output/tail capture, cancellation, and cleanup. Hosts
provide environment construction, command resolution/cache, directory expansion,
termination policy, diagnostics, read preflight, and optional process-registration
callbacks. Output-mode values, argument redaction, and launch-error messages keep
RepoPrompt's characterized semantics. Configuration has explicit command,
working-directory and search-path inputs; there is no ambient app lookup.

Every child has one waiter and cleanup owner. Consumer cancellation, buffered-task
cancellation and cancelAll cancel that waiter instead of racing separate reapers.
ProcessKit readers deliver queued bytes before EOF; descendant-held pipes have a
bounded drain. Permits are returned after cleanup, and queued cancellation never
launches a child. The former independent reader/watchdog/reaper paths are removed.
Buffered execution retains full output; streaming diagnostic tails retain their
configured limits and input sampling remains opt-in. This product links only
ProcessKit and ProcessStreamFraming; framing stays outside the process primitives.
