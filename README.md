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
