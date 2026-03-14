# Claude Backend ACP Replacement Plan

## Context

Symphony currently has two agent transports with very different runtime quality:

- Codex uses a real long-lived JSON-RPC client over stdio and supports persistent sessions, structured streaming updates, remote workers, and robust timeout/error handling.
- Claude currently uses a `claude -p` subprocess per turn. That path is operationally weaker: no persistent session, no structured streaming, limited parity with the Codex client, and more bespoke logic.

We do want to replace the Claude path with ACP. The important constraint is how we do it:

- Phase 1 must replace Claude transport with ACP.
- Phase 1 must also close the functional gap with the Codex runtime.
- Phase 1 should avoid widening the backend/config surface more than necessary, because this branch already carries local backend-routing changes that are not in `oai/main`.

## Goal

Replace the current Claude subprocess implementation with a real ACP-backed adapter while preserving the current Symphony backend contract and bringing Claude runtime behavior much closer to Codex.

Success for phase 1 means:

- `claude-code` runs through a real ACP adapter, not `claude -p`.
- Stage routing and orchestrator integration keep working with minimal churn.
- Claude emits the same class of lifecycle events Symphony already expects from Codex-like backends.
- Remote worker, workspace safety, timeout, and unavailable-backend behavior are first-class instead of ad hoc.

## Non-Goals For Phase 1

- Do not relax backend validation to "any string". Validation should expand only to configured ACP backends plus built-ins.
- Do not refactor stage routing, orchestrator flow, or the Codex client unless required for a narrow compatibility seam.
- Do not claim Gemini/OpenCode are supported in phase 1 just because the registry exists.

## Recommended Shape

### Keep the public Symphony backend names stable

Phase 1 should introduce a real ACP backend adapter, but keep the externally configured backend names stable.

This means phase 1 should preserve:

- `agent.backend: claude-code`
- `"claude"` -> `"claude-code"` aliasing
- `SymphonyElixir.AgentBackend` routing contract
- stage routing behavior
- `{:backend_unavailable, backend_name, reason}` error shape

This allows us to move Claude onto a proper ACP transport while still keeping backend expansion controlled through explicit configuration.

### Introduce a real ACP adapter now

The implementation should add a reusable ACP client module and a real `AgentBackend.ACP` adapter in phase 1.

Recommended split:

1. `lib/symphony_elixir/acp/client.ex`
   - ACP transport/runtime client
   - Handles stdio/ndjson framing, request correlation, session lifecycle, notifications, permissions, and timeouts

2. `lib/symphony_elixir/agent_backend/acp.ex`
   - Real backend adapter that delegates to `Acp.Client`
   - Used for `claude-code` in phase 1

3. `lib/symphony_elixir/agent_backend/claude.ex`
   - Removed once `claude-code` is routed to `AgentBackend.ACP`
   - The backend name stays `claude-code`; only the implementation changes

This gives us the full ACP adapter shape now, including the generic ACP registry, without claiming that every ACP-capable agent is production-ready on day one.

## Functional Parity Requirements

The new ACP-backed `claude-code` path should be judged against `codex/app_server.ex`, not just against the current Claude subprocess.

### Required parity items

1. Persistent session lifecycle
   - `start_session/2` opens the ACP process once
   - `run_turn/4` reuses that session
   - `stop_session/1` closes it cleanly

2. Structured lifecycle events
   - Emit `:session_started`
   - Emit streaming `:notification` updates while the turn is running
   - Emit `:turn_completed` on normal completion
   - Emit `:turn_ended_with_error` on failure

3. Worker/runtime parity
   - Local stdio launch via `bash -lc`
   - Remote worker launch via `SSH.start_port/3`
   - Same workspace validation and path-safety guarantees as Codex

4. Timeout parity
   - startup/read timeout
   - turn timeout
   - stall timeout or equivalent inactivity timeout while waiting for stream updates

5. Failure classification
   - command not found -> `{:backend_unavailable, "claude-code", reason}`
   - abnormal process exit -> structured backend error
   - malformed ACP frames -> structured protocol error
   - permission dead-end -> structured backend error, not silent hang

6. Metadata parity
   - preserve `backend`, `session_id`, `thread_id`/ACP session id, `turn_id` where possible
   - include port metadata such as worker host and pid when available

7. Orchestrator compatibility
   - existing status/dashboard/comment flows continue to work without new orchestration concepts

### Nice-to-have, not required for first merge

- shared lower-level helpers between Codex and ACP transport layers
- richer normalization of tool call/result events if the current UI does not yet consume them

## ACP Protocol Notes

Implement against the current ACP spec and the real `claude-agent-acp` behavior, not against guessed method shapes.

At minimum verify and code to:

- `initialize` request/response shape
- client/server capability negotiation
- `session/new` params and result shape
- `session/prompt` request params and completion response
- streaming session update notification method and payload kinds
- permission request/response flow
- mode discovery and mode setting behavior if Claude ACP exposes modes

Do not hardcode speculative ACP payloads if they are not confirmed by the package/spec.

## Claude ACP Server Packaging

The Claude ACP "server mode" should live in-repo under:

- `nano/plugins/acp-claude`

Recommended structure:

- `nano/plugins/acp-claude/package.json`
- `nano/plugins/acp-claude/src/...`
- `nano/plugins/acp-claude/dist/...`

The job of this package is narrow:

- wrap or invoke the upstream Claude ACP server entrypoint we standardize on
- pin the runtime/build shape we expect in this repo
- give Symphony one stable command to execute

### Runtime model

Elixir should not depend on a separately managed long-lived Claude ACP daemon for phase 1.

Instead:

- the package is built ahead of time
- `acp.backends.claude-code.command` points at the built executable or Node entrypoint
- `Acp.Client` launches it on demand via `Port` locally or `SSH.start_port/3` remotely
- the process lives for the duration of the backend session and is torn down by Symphony when the session ends

This keeps the operational model aligned with Codex:

- Symphony owns process lifecycle
- no extra service manager is required
- logs/errors stay attached to the worker session that spawned them

If we later need a daemonized/shared transport process, that should be a separate optimization, not the phase-1 baseline.

## Proposed File Changes

### New file

1. `lib/symphony_elixir/acp/client.ex`
   - ACP session client modeled after the runtime discipline of `codex/app_server.ex`
   - Responsibilities:
     - spawn and supervise the port
     - encode/decode ndjson messages
     - correlate requests by id
     - process ACP notifications while awaiting turn completion
     - respond to permission requests according to non-interactive Symphony rules
     - normalize ACP events into Symphony backend events

### Modified files

2. `lib/symphony_elixir/agent_backend/acp.ex`
   - Thin backend adapter over `Acp.Client`
   - Owns the backend session contract for ACP-backed agents

3. `lib/symphony_elixir/agent_backend/claude.ex`
   - Delete after `claude-code` is routed to `AgentBackend.ACP`
   - Preserve `claude-code` as the configured backend name even though the adapter module changes

4. `lib/symphony_elixir/config/schema.ex`
   - Add an `acp` config block in phase 1 with a generic backend registry
   - Registry shape:
     - `acp.backends.<name>.command`
     - optional per-backend overrides such as env, timeout, or mode config if actually required
   - Shared ACP runtime knobs can live at the top level of `acp`
   - Backend validation should allow:
     - built-in `codex`
     - configured ACP backend names
   - Phase 1 still only needs production support for `claude-code`

5. `lib/symphony_elixir/agent_backend.ex`
   - Route `claude-code` to `AgentBackend.ACP`
   - More generally, route configured ACP backend names to `AgentBackend.ACP`
   - Keep fallback behavior and backend contract otherwise unchanged

6. `lib/symphony_elixir/agent_runner/stage_run.ex`
   - If needed, generalize the existing backend-unavailable match from Claude-specific to backend-agnostic
   - Keep this change minimal and isolated

7. `elixir/WORKFLOW.md` and `elixir/README.md`
   - Update docs to reflect that `claude-code` now uses ACP transport
   - Document any config field changes

## Config Shape For Phase 1

Phase 1 should introduce the generic ACP registry now:

```yaml
agent:
  backend: claude-code
  stage_backends:
    frontend: claude-code

acp:
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
  backends:
    claude-code:
      command: claude-agent-acp
```

Keep shared defaults at `acp.*` and backend-specific values under `acp.backends.<name>`.

If the ACP server requires an explicit permissions/mode setting, add that only after confirming the real protocol shape.

## Implementation Order

1. Confirm the real ACP wire contract for `claude-agent-acp`.
2. Implement `Acp.Client` with:
   - port startup
   - request/response correlation
   - ACP session creation
   - turn execution
   - notification loop
   - permission handling
   - timeout and exit handling
3. Add `AgentBackend.ACP`.
4. Add `acp` schema/config support, including configured-backend validation.
5. Route configured ACP backend names to `AgentBackend.ACP`, then delete the old Claude subprocess adapter.
6. Verify `claude-code` is the only supported ACP backend in tests/docs for phase 1.
7. Make the smallest necessary compatibility change in `StageRun`.
8. Update docs.
9. Run parity-focused tests plus existing regression suite.

## Test Plan

### Unit tests

1. ACP happy path
   - mock ACP server script responds to initialize, session creation, prompt, streaming updates, and completion

2. Permission flow
   - mock ACP server requests permission mid-turn
   - verify Symphony responds correctly and the turn continues

3. Timeout cases
   - startup timeout
   - read timeout
   - stall timeout
   - turn timeout

4. Failure cases
   - command missing / exit 127
   - non-zero exit after startup
   - malformed ndjson
   - invalid ACP response id / missing required fields

5. Remote worker path
   - same remote-port launch contract used by Codex

### Integration tests

1. Real `claude-agent-acp` smoke test in a workspace
2. Stage-routed issue using `claude-code`
3. Existing Codex backend regression to ensure no behavioral drift

## Phase 1 Smoke Test

In addition to the Elixir-side unit coverage, phase 1 should include one real end-to-end smoke test under `nano/`.

### Scope

- Create a tiny dedicated integration fixture workspace under `nano/`
- Run Symphony end to end against that workspace with:
  - `agent.backend: codex`
  - `agent.backend: claude-code`
- Use the cheapest models/configurations we have access to for each backend
- Keep the task intentionally trivial so the test is fast and cheap

### Auth prerequisite

- The smoke test should assume existing local CLI auth is already available through OAuth-backed session state on disk or equivalent shell-visible credentials.
- The smoke test should not depend on copying browser session state or manually injecting fresh API keys at runtime if local CLI auth is already working.
- Before running the smoke test, verify from the shell that both backends can start non-interactively with the locally available auth state.
- If either backend requires an interactive login prompt, treat that as an environment prerequisite failure rather than a product failure.

### Suggested task

Use a single easy implementation target such as:

- create a tiny file
- update a tiny function
- or make a one-line visible output change

The point is not deep capability coverage. The point is proving that:

- the orchestrator can create the workspace
- the backend session starts
- the agent can make a small change
- the run exits cleanly

### Success criteria

One smoke test is enough for phase 1:

1. prepare the same tiny test workspace in `nano/`
2. run once with Codex
3. run once with Claude ACP
4. verify the expected trivial file change was made
5. verify Symphony observed a successful run rather than a startup/transport failure

If this is flaky or too expensive, reduce scope further rather than expanding it. The goal is "implement something easy and call it done."

## Phase 2, Only After Phase 1 Lands

Once the ACP adapter is stable for `claude-code` and parity-tested, then consider a follow-up PR that:

- adds Gemini/OpenCode support
- factors shared transport concerns between Codex and ACP if duplication is proven

That phase should be justified by concrete second-backend usage, not assumed upfront.
