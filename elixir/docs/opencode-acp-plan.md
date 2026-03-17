# OpenCode ACP First-Class Support Plan

## Goal

Add `opencode` as a built-in ACP backend that feels as close to first-class as Codex as the upstream protocol allows:

- selectable anywhere `agent.backend` or `agent.stage_backends` is used
- packaged in-repo the same way `nano/plugins/acp-claude` is packaged today
- covered by repo-local smoke tests
- runnable inside the existing SSH/Docker worker test shape
- exercisable through the host CLI flow in `nano/conductor/symphonyctl.py`

OpenCode already exposes an ACP entrypoint via `opencode acp`, so this is primarily a Symphony packaging, defaults, and test-hardening project rather than a new transport design.

## Current state

- Symphony already has a generic ACP adapter in `lib/symphony_elixir/acp/client.ex`.
- ACP backends are already routed generically through `lib/symphony_elixir/agent_backend/acp.ex`.
- Config validation already supports configured ACP backend names in `lib/symphony_elixir/config/schema.ex`.
- Repo-local smoke only covers `codex` and `claude-code` in `nano/smoke/backend_smoke.exs`.
- Live Docker workers are currently Codex-oriented:
  - image installs `@openai/codex`
  - compose mounts `~/.codex/auth.json`
  - entrypoint only prepares Codex auth paths

That means the runtime seam is mostly in place, but OpenCode is not yet treated as a shipped backend.

## What "first-class" should mean here

For OpenCode, "first-class" should mean Symphony itself ships a stable opinionated path, not that OpenCode becomes identical to Codex internally.

Required outcomes:

- `opencode` is a built-in ACP backend name, not just an undocumented custom backend example.
- `agent.backend: opencode` works out of the box when the packaged wrapper is installed.
- status dashboard, tracker state, retries, backend-unavailable handling, remote worker launch, and stage routing behave exactly like other supported backends.
- repo docs and examples show `opencode` alongside `codex` and `claude-code`.
- smoke, Docker worker, and host CLI coverage exist specifically for `opencode`.

Non-goals:

- do not invent fake Codex-only controls such as approval-policy or reasoning-effort support if OpenCode ACP does not expose them
- do not fork the ACP runtime per backend unless OpenCode forces a confirmed protocol compatibility seam

## Recommended product shape

### 1. Ship OpenCode as a default ACP backend

Extend the default ACP registry in `lib/symphony_elixir/config/schema.ex` so Symphony ships:

```yaml
acp:
  backends:
    claude-code:
      command: claude-agent-acp
    opencode:
      command: /repo-local/wrapper/for/opencode
```

Recommended details:

- keep `opencode` as the canonical backend name
- do not alias it to something vague like `open`
- preserve the existing generic ACP registry so user-defined backends still work
- update validation/docs so `codex`, `claude-code`, and `opencode` read as the officially supported set

### 2. Add a repo-local OpenCode wrapper package

Add a new package under:

- `nano/plugins/acp-opencode`

The job of this package should be the same as the Claude wrapper:

- pin the repo-supported OpenCode install method
- provide one stable command for Symphony to execute
- make local smoke and Docker runs independent from whatever the host has globally installed

Recommended structure:

- `nano/plugins/acp-opencode/package.json`
- `nano/plugins/acp-opencode/bin/acp-opencode.mjs`
- optional `README.md`

The wrapper should:

- launch `opencode acp`
- forward extra args
- allow env injection for auth/runtime
- fail fast with a clear stderr message if OpenCode is not installed or auth is missing

### 3. Keep ACP runtime generic

Do not add an `AgentBackend.OpenCode` module unless the upstream behavior forces it.

Instead:

- keep `lib/symphony_elixir/acp/client.ex` generic
- only add narrow compatibility shims if OpenCode's ACP notifications or session payloads differ in confirmed ways
- extend tests in `elixir/test/symphony_elixir/acp_client_test.exs` for any OpenCode-specific mode/model behavior that needs normalization

### 4. Treat model selection as a normal ACP backend override

OpenCode should use the existing ACP config surface:

- `acp.backends.opencode.command`
- `acp.backends.opencode.env`
- `acp.backends.opencode.model`
- backend-local timeout overrides if needed

Do not add OpenCode-only top-level config unless required by upstream.

## Docker and worker plan

The current Docker worker setup is too Codex-specific to count as proper OpenCode coverage.

### 1. Expand the live worker image

Update:

- `elixir/test/support/live_e2e_docker/Dockerfile`
- `elixir/test/support/live_e2e_docker/docker-compose.yml`
- `elixir/test/support/live_e2e_docker/live_worker_entrypoint.sh`

Recommended behavior:

- install OpenCode in the worker image
- keep Codex installed as well
- support auth through env vars and optional mounted config files instead of one hardcoded auth file path

For OpenCode specifically, prefer an env-driven auth shape over hidden mutable container state. At minimum support:

- `OPENCODE_API_KEY`
- optional OpenCode config directory mount if upstream requires more than the API key

### 2. Make backend availability explicit in worker startup

The entrypoint should validate the required executables for the requested scenario and emit a clear failure if they are missing.

Example checks:

- `codex --version`
- `opencode --version`

Do not silently start a worker image that lacks a supported backend binary.

### 3. Keep Codex and ACP test concerns separable

Do not force every Docker run to authenticate every backend.

Use compose env or profiles so we can run:

- Codex-only worker tests
- OpenCode ACP worker tests
- combined regression runs when credentials exist

## Test plan

### 1. Expand repo-local smoke

Update:

- `nano/smoke/backend_smoke.exs`
- `nano/smoke/run_backend_smoke.sh`

Required changes:

- add `opencode` to the backend matrix
- allow `SYMPHONY_SMOKE_OPENCODE_COMMAND`
- allow `SYMPHONY_SMOKE_OPENCODE_MODEL`
- install wrapper dependencies before running smoke

The smoke contract should stay identical to Codex/Claude:

- write one exact file
- verify it
- stop without user interaction

### 2. Add config and routing tests

Update:

- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/test/symphony_elixir/stage_routing_test.exs`

Add coverage for:

- built-in `opencode` backend acceptance
- stage routing to `opencode`
- backend-unavailable classification for `opencode`
- per-stage model override flowing through ACP config

### 3. Add ACP runtime compatibility tests

Update:

- `elixir/test/symphony_elixir/acp_client_test.exs`

Add a mock-server-backed case that uses backend name `opencode` and proves Symphony is not accidentally relying on Claude-only assumptions.

### 4. Add Docker-backed live validation

Extend the live worker path so at least one test scenario runs an ACP backend over SSH into the disposable Docker workers.

Prefer a dedicated ACP live test over overloading the existing Codex-only wording in `elixir/test/symphony_elixir/live_e2e_test.exs`.

Minimum success criteria:

- Symphony launches on a Docker-backed SSH worker
- `agent.backend: opencode` completes a real turn
- result side effect lands in the workspace
- backend lifecycle events are visible in the same status surfaces used by Codex

### 5. Add host CLI coverage

The host CLI should be able to start and manage a Symphony instance whose workflow uses OpenCode.

Update:

- `nano/conductor/tests/test_symphonyctl.py`
- `nano/conductor/symphony-registry.example.json`

Recommended additions:

- registry fixtures that point at an OpenCode workflow
- `ensure`/`status`/`stop` tests that prove the host CLI does not care whether the configured backend is Codex or OpenCode
- example registry/docs showing how to point a local project at an OpenCode-backed workflow

If needed, add a tiny integration fixture workflow under `nano/` so host-CLI tests can exercise a real backend selection without depending on Linear.

## Docs and UX

Update:

- `elixir/README.md`
- `template-webdev-workflow.md`
- any backend comparison/docs that currently imply Codex plus Claude are the only shipped choices

Required doc changes:

- show `opencode` as an official ACP backend
- document the expected auth env vars
- document the wrapper command path for repo-local smoke/testing
- explain the limits honestly: Codex app-server and OpenCode ACP are both supported, but they are different upstream runtimes

## Implementation order

1. Add `nano/plugins/acp-opencode`.
2. Add `opencode` to built-in ACP defaults and docs.
3. Extend smoke coverage to include OpenCode.
4. Extend config/routing/runtime unit tests.
5. Upgrade Docker worker image and compose wiring for OpenCode auth and binary availability.
6. Add at least one Docker-backed ACP live test.
7. Add `symphonyctl` and registry fixture coverage.

## Ship criteria

Do not call OpenCode first-class until all of the following are true:

- `agent.backend: opencode` works without custom backend registration
- smoke passes locally for `opencode`
- Docker worker image can run `opencode`
- at least one SSH/Docker-backed live test covers `opencode`
- `symphonyctl ensure/status/stop` is tested against an OpenCode workflow shape
- docs show OpenCode as an officially supported backend
