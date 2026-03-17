# Gemini CLI ACP First-Class Support Plan

## Goal

Add `gemini-cli` as an officially supported ACP backend with the same Symphony-level quality bar we expect from Codex and other shipped backends:

- built-in backend name and documented workflow usage
- repo-local packaged launcher
- deterministic auth/runtime setup for local and Docker workers
- smoke, Docker/SSH, and host-CLI coverage

Gemini CLI already has an ACP mode upstream via `gemini --acp`. The main work is making Symphony own a stable packaging and test story instead of treating Gemini as a one-off custom backend.

## Why this needs its own plan

Gemini is not just "another ACP binary" from an operational standpoint.

Compared to OpenCode, Gemini has more authentication modes:

- cached interactive login
- `GEMINI_API_KEY`
- `GOOGLE_API_KEY` plus Vertex AI mode
- ADC / service-account flows

That makes Docker and headless test design the critical path. If we do not solve non-interactive auth cleanly, Gemini will look supported in config but fail in CI and worker environments.

## Current state

- Symphony ACP transport already exists and is generic.
- Config already supports arbitrary ACP backends, but only `claude-code` is shipped as a default built-in.
- Docker worker test infrastructure currently assumes Codex auth file mounts and does not model Gemini auth.
- host CLI tests only prove `symphonyctl` can start Symphony generally; they do not cover backend-specific workflow fixtures.

## What "first-class" should mean for Gemini

Required outcomes:

- `gemini-cli` is shipped as a built-in ACP backend name
- `gemini` is accepted as a friendly alias that normalizes to `gemini-cli`
- the default supported launch path is stable and repo-owned
- non-interactive auth is explicitly documented and testable
- Docker worker coverage proves Gemini can run on remote workers, not just on a developer laptop with cached login state
- host CLI coverage exists for a Gemini-backed workflow

Non-goals:

- do not depend on browser-driven OAuth during automated tests
- do not mark Gemini as first-class based only on config validation
- do not add Gemini-specific orchestration concepts if ACP runtime behavior fits the existing generic client

## Recommended backend shape

### 1. Ship `gemini-cli` as a default ACP backend

Extend built-in ACP defaults in `lib/symphony_elixir/config/schema.ex` with:

```yaml
acp:
  backends:
    gemini-cli:
      command: /repo-local/wrapper/for/gemini-cli
```

Recommended naming:

- canonical backend name: `gemini-cli`
- alias: `gemini`

This mirrors the current `"claude" -> "claude-code"` normalization pattern and gives users the ergonomic name they will actually try.

### 2. Add a repo-local Gemini wrapper package

Add:

- `nano/plugins/acp-gemini-cli`

Recommended structure:

- `nano/plugins/acp-gemini-cli/package.json`
- `nano/plugins/acp-gemini-cli/bin/acp-gemini-cli.mjs`
- optional `README.md`

Wrapper responsibilities:

- launch `gemini --acp`
- pass through extra args
- normalize env setup for headless use
- emit a clear startup error when no supported non-interactive auth is configured

The wrapper is especially important here because Gemini's auth matrix is broader than Claude's or OpenCode's.

## Authentication plan

### 1. Standardize on non-interactive auth for tests

For automated tests and Docker workers, prefer environment-driven auth only.

Supported automated auth modes should be:

- `GEMINI_API_KEY`
- Vertex mode via env when explicitly requested
- optional ADC/service-account path only if we decide to support it in CI

Do not rely on a cached interactive login inside Docker or CI.

### 2. Make auth mode explicit in config/docs

Add clear guidance that `gemini-cli` in Symphony workers should be configured with env vars, for example through:

- `acp.backends.gemini-cli.env`
- host-level exported env vars
- compose env files for Docker workers

Do not hide Gemini auth inside undocumented container state.

## Runtime and compatibility plan

### 1. Keep the ACP client generic unless proven otherwise

Start with the current `lib/symphony_elixir/acp/client.ex`.

Only add Gemini-specific handling if verified upstream behavior requires it, for example:

- notification method names that differ in meaningful ways
- session initialization requirements Symphony does not currently satisfy
- auth/setup requests that need explicit handling in the wrapper

### 2. Preserve existing Symphony surfaces

`gemini-cli` should participate in:

- `agent.backend`
- `agent.stage_backends`
- backend unavailable and retry handling
- tracker updates and dashboard presentation
- remote worker launch over SSH

No Gemini-only execution path should bypass the current ACP adapter.

## Docker and worker plan

This is the most important part of the Gemini rollout.

### 1. Upgrade the live worker image for Gemini

Update:

- `elixir/test/support/live_e2e_docker/Dockerfile`
- `elixir/test/support/live_e2e_docker/docker-compose.yml`
- `elixir/test/support/live_e2e_docker/live_worker_entrypoint.sh`

Required changes:

- install Gemini CLI in the worker image
- support env-file or compose env injection for Gemini auth
- verify `gemini --version` at startup for Gemini scenarios

### 2. Support backend-specific auth injection

The compose setup should stop assuming one shared auth mount format.

Recommended model:

- keep Codex auth file mount for Codex scenarios
- add env-based Gemini auth injection
- allow OpenCode and Gemini to be turned on independently

That gives us reproducible matrix runs without forcing every contributor to configure every vendor credential.

### 3. Add a Docker readiness check for headless Gemini

Before Symphony uses a Gemini Docker worker, run a simple non-interactive check such as:

- `gemini --acp --help`
- or a wrapper-level `--version`/sanity probe if upstream ACP mode blocks without auth

The goal is to fail fast on missing binary or broken runtime before the orchestrator gets involved.

## Test plan

### 1. Expand backend smoke

Update:

- `nano/smoke/backend_smoke.exs`
- `nano/smoke/run_backend_smoke.sh`

Required changes:

- add `gemini-cli` to the smoke matrix
- support `SYMPHONY_SMOKE_GEMINI_COMMAND`
- support `SYMPHONY_SMOKE_GEMINI_MODEL`
- support `SYMPHONY_SMOKE_GEMINI_API_KEY` or equivalent env passthrough

Smoke should prove:

- non-interactive Gemini auth works
- ACP session startup succeeds
- one file-edit task completes end-to-end

### 2. Add config and alias tests

Update:

- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/test/symphony_elixir/stage_routing_test.exs`

Add coverage for:

- built-in `gemini-cli`
- alias normalization from `gemini` to `gemini-cli`
- stage routing to Gemini
- backend unavailable behavior for missing Gemini command

### 3. Add ACP client coverage under Gemini backend name

Update:

- `elixir/test/symphony_elixir/acp_client_test.exs`

The goal is not to mock Gemini internals. The goal is to prove the Symphony ACP client works correctly when the backend identity is `gemini-cli` and any backend-local options are applied.

### 4. Add Docker-backed SSH validation

Extend `elixir/test/symphony_elixir/live_e2e_test.exs` or add a sibling live test so Gemini runs through:

- Docker worker
- SSH transport
- ACP backend session

Minimum success criteria:

- Symphony launches a Gemini-backed turn remotely
- workspace side effect is created
- the run surfaces the same lifecycle metadata and terminal result handling expected from other backends

### 5. Add host CLI coverage

Update:

- `nano/conductor/tests/test_symphonyctl.py`
- `nano/conductor/symphony-registry.example.json`

Add workflow fixtures and tests proving `symphonyctl ensure/status/stop` works with a Gemini-backed project entry, not just generic stubbed workflows.

If needed, add a tiny sample workflow under `nano/` that sets:

```yaml
agent:
  backend: gemini-cli
acp:
  backends:
    gemini-cli:
      command: ...
      env:
        GEMINI_API_KEY: ...
```

## Docs and examples

Update:

- `elixir/README.md`
- `template-webdev-workflow.md`
- any conductor docs or example configs that should expose Gemini as an official option

Required documentation points:

- canonical backend name and alias
- recommended non-interactive auth setup
- wrapper package path used by repo-local smoke
- Docker worker env requirements for Gemini scenarios

## Implementation order

1. Add `nano/plugins/acp-gemini-cli`.
2. Add built-in backend default plus alias normalization.
3. Wire non-interactive auth env handling through wrapper and smoke scripts.
4. Expand smoke coverage.
5. Expand config/routing/runtime tests.
6. Upgrade Docker worker image and compose env handling.
7. Add at least one Docker-backed SSH live validation.
8. Add `symphonyctl` fixture coverage and docs.

## Ship criteria

Do not call Gemini first-class until all of the following are true:

- `agent.backend: gemini-cli` works without custom backend registration
- `agent.backend: gemini` normalizes correctly
- repo-local smoke passes with non-interactive auth
- Docker workers can run Gemini in headless mode
- at least one SSH/Docker-backed live test covers Gemini
- `symphonyctl` tests cover a Gemini-backed workflow
- docs clearly explain how Gemini auth works in headless worker environments
