---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "<SYMPHONYCLAW_LINEAR_PROJECT_SLUG>"
  assignee: me
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate

polling:
  interval_ms: 10000

workspace:
  root: .symphony/workspaces

hooks:
  after_create: |
    sh .symphony/bootstrap.sh
  timeout_ms: 180000

agent:
  backend: codex
  stage_backends:
    frontend: claude-code
  max_concurrent_agents: 4
  max_turns: 40
  max_input_tokens: 1000000
  max_output_tokens: 100000

codex:
  command: codex app-server
  model: gpt-5.3-codex
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite

acp:
  backends:
    claude-code:
      command: claude-agent-acp

server:
  port: 46110
---

You are building `symphonyclaw`.

This project is a multi-channel planner/operator that sits in front of Symphony. It is not a
replacement for Symphony Nano.

## Authoritative documents

Before making any implementation decision, read and follow:

1. `nano/symphonyclaw/plan.md`
2. the current repository structure and relevant implementation files
3. any in-repo docs that constrain the touched subsystems

Treat `nano/symphonyclaw/plan.md` as the source of truth for architecture and sequencing unless the
current issue explicitly narrows the scope.

## Primary architecture rules

Do not violate these rules unless the issue explicitly changes the architecture:

- keep the planner/control-plane core in Elixir/Phoenix
- keep channel connectors in TypeScript sidecars
- use the Vercel Chat SDK in the connector sidecar
- use NATS JetStream for sidecar <-> core transport
- use Postgres for durable application state
- use Oban for Elixir-internal jobs and retries
- use Phoenix LiveView plus Salad UI for the dashboard
- keep Symphony Nano as the downstream coding execution runtime
- do not collapse connector transport logic into the Elixir app
- do not rebuild Symphony inside `symphonyclaw`

## Project objective

Implement `symphonyclaw` so that:

- users can interact through multiple channels
- each channel conversation has its own durable session
- multiple personas and bot identities are supported
- the system can answer directly, use skills, or create/update engineering work
- engineering work is routed into Symphony through Linear and a mapped Symphony team
- operators can inspect the system through a Phoenix dashboard

## Build order

Default implementation order:

1. foundation and config loading
2. durable schemas for workspaces, personas, bot identities, channel bindings, sessions, teams
3. queue boundary and message envelopes
4. sidecar skeleton using the Vercel Chat SDK
5. planner/session/persona routing in Elixir
6. Symphony and Linear bridge
7. dashboard using Salad UI
8. crash recovery, retries, idempotency, and operator tooling

Prefer the smallest end-to-end slice that proves the architecture instead of building isolated
subsystems without integration.

## Session and persona rules

- one external thread or conversation maps to one internal session
- session identity is scoped by workspace, connector, bot identity, channel, and thread
- personas are first-class objects with policy, not loose prompt snippets
- different channels may map to different personas and different Symphony teams

## Queue and reliability rules

- all connector/core messages must be safe under at-least-once delivery
- handlers must be idempotent
- sidecars must emit heartbeats
- sidecar crashes must not lose durable work
- PM2 may be used for sidecar restart in local dev and simple single-host deployments

## Dashboard rules

- the dashboard must be Phoenix LiveView
- the dashboard should use Salad UI components installed locally, not a thin placeholder shell
- at minimum expose system health, sidecar health, queue health, active sessions, personas,
  channel bindings, Symphony teams, and dispatch runs

## Code quality rules

- read existing code before adding new code
- keep boundaries explicit and inspectable
- prefer stable contracts over clever abstractions
- keep transport-specific behavior in TypeScript and business logic in Elixir
- keep changes focused on the current issue
- update docs when architecture or config meaning changes

## Handling implementation issues

If an issue only touches one slice, stay narrow while preserving the overall architecture.

If an issue conflicts with `nano/symphonyclaw/plan.md`, call out the conflict explicitly in the
workpad and choose the smallest change that preserves the intended direction.

## Completion bar

Do not consider a task complete unless:

- the implementation matches the plan for the touched area
- relevant tests pass for the touched area
- docs/config/examples are updated when behavior changes
- the resulting system remains aligned with the Elixir-core / TypeScript-sidecar architecture
