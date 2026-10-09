# AgentExecutionKit

Shared agent execution infrastructure. The initial `AgentProcessSupport` product
owns launch-context classification, environment sanitization, and child-process
registry ownership extracted from RepoPrompt's ProcessCore. Host environment
markers are explicit inputs. There are no app/UI imports or implicit settings.

Swift 6, strict concurrency, macOS 27. Build and test with `swift build` and
`swift test`. Process primitives remain in ProcessKit. Provider protocol framing,
clients, sessions, persistence, and MCP hosting are subsequent adoption slices;
the initial release does not claim to contain those implementations.

Source lineage: RepoPrompt (`github.com/ajmcclary/RepoPrompt`), Apache-2.0.
