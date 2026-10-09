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

`AgentHeadlessContracts` exposes the SDK-neutral headless message and provider
interface. `AgentCodexExec` owns the complete Codex exec stream lifecycle,
line framing, current/legacy event parsing, invocation correlation, stderr
filtering, bounded error capture, failure classification, one broken-server retry,
and completion/failure delivery. It consumes the injectable CLI execution surface.
Hosts provide policy validation, per-attempt launch contexts/executors, MCP event
observation and cleanup, broken-server state, model-unavailable guidance, and
logging. Executable/auth/MCP inventories and application settings remain explicit
host policy; this product reads no bundle, defaults suite, or process environment.

Every attempt has its own parser and execution context. Replacement and disposal
retire prior tasks before starting a replacement; stale observation callbacks
cannot enter a later stream. Cleanup runs after success, failure, and cancellation.
A logical run emits one message_stop, including clean exits without a provider
completion frame. Model-unavailability never substitutes a model or retries.
Build the products with `swift build --target AgentHeadlessContracts` and
`swift build --target AgentCodexExec`; all public values are Sendable and contain
no application or external SDK type.

`AgentClaudeHeadless` owns the Claude headless CLI dialect, current/legacy event
projection, final-content authority, usage/session identities, bounded diagnostic
capture, failure mapping, and stream execution/cancellation/cleanup. It consumes
`AgentCLIExecution` and `AgentHeadlessContracts`; it adds no dependency on native
session controllers, HTTP, storage, or UI. Public parser values are core AI stream
results. The host supplies resolved stdin/arguments/environment removals, one
executor per run, MCP observation/cleanup, credit-balance guidance, and diagnostics.
Reasoning extraction is an explicit input. Provider completion closes the process
promptly; duplicate/trailing completions do not escape, and a successful process
exit without a result produces one completion. Replacement/disposal await retired
producers; cancelled preparation still cleans any returned context before launch.

`AgentClaudeProtocol.ClaudePromptDelivery` also owns the existing XML instruction
wrapper and whitespace rules used by both headless and native hosts. Prompt mode,
credentials, permission flags, native-tool restrictions, CLI model arguments, and
MCP inventory remain host choices. Build the headless product independently with
`swift build --target AgentClaudeHeadless`. Native Claude session ownership and
Gemini/ACP execution remain subsequent extraction slices.

`AgentGeminiHeadless` owns Gemini headless CLI stream execution, per-run session
capture, typed event parsing/projection, diagnostic/error precedence, failure
mapping, cancellation, and cleanup. Hosts explicitly supply launch inputs,
run-scoped executors, MCP observation/cleanup, and diagnostics. Public event
values retain serialized tool arguments without sharing Foundation dictionaries;
the legacy tool-summary presentation remains unchanged. Malformed JSON and
provider error results fail the stream, stderr remains visible, and exit code 148
keeps Gemini's API-error classification. Replacement and disposal await retired
runs; parser/session state cannot leak into a replacement. A successful run emits
one completion, including clean exits without result frames.

`GeminiPromptDelivery` preserves explicit file references while escaping stray
at-signs in the user channel. Hosts retain MCP inventories, persistent system
settings, CLI model/resume flags, credentials, and executable/environment policy.
Build independently with `swift build --target AgentGeminiHeadless`; the product
links only headless contracts, CLI execution, AI values, and stream framing.
Gemini ACP execution and native session controllers remain subsequent slices.

`AgentACPHeadless` owns the live one-shot ACP headless bridge: stream retirement,
bootstrap/configure/prompt sequencing, approval fallback, event forwarding,
terminal errors, cancellation, and single shutdown ownership. Hosts prepare a
controller through explicit operations and supply support/admission, error
normalization, session configuration, MCP correlation, provider identity, and
approval policy. Its event vocabulary uses existing AgentRuntimeKit approval and
session values. The product imports no app module, UI, transport, or persistence.

Old-consumer cancellation is scoped to its stream token and cannot dispose a
replacement. Replacement/disposal await retired producers and controller cleanup;
concurrent disposal shares shutdown. The legacy app lock/asserted-Sendable
lifecycle owner is no longer needed. Native ACP transport/session controllers and
prompt-only provider orchestration remain subsequent extraction boundaries.

`AgentNativeProcessTransport` owns child spawn, stdin writes, stdout/stderr reader
lifetimes, the process waiter, generation metadata, and physical teardown. It is
an actor-confined synchronous component: tasks capture only explicit callbacks
and values, never its mutable state. Launch inputs, preflight, waiting, direct
reaping, and diagnostic labels are supplied by the host. Protocol framing,
requests, admission/digest checks, executable/environment resolution, session
policy, MCP registration, and provider identity remain outside the transport.

Termination releases transport state before awaiting cleanup. Its sealed Sendable
lease shares one cleanup task across repeated/concurrent callers. An installed
waiter exclusively owns reaping; a setup failure before waiter installation uses
the injected direct reap. Natural-exit acknowledgement releases already-reaped
state, and stale generations cannot clear/write/invalidate a replacement. Dropped
owners and unused leases also initiate cleanup through the same ownership path.
The product depends only on ProcessKit; it adds no protocol/UI/storage dependencies
to the process primitives. Build it independently with
`swift build --target AgentNativeProcessTransport`.
