# SymphonyClaw Plan

## Goal

Build `symphonyclaw` as a multi-channel planner/operator that sits in front of Symphony.

Core intent:

- users talk to bots in Slack, Discord, Telegram, and similar channels
- `symphonyclaw` decides whether to answer directly, use local skills, or create/update tracked engineering work
- `symphonyclaw` hands engineering execution off to Symphony through Linear
- Symphony remains the issue executor, not the front-door planner

## Product Definition

`symphonyclaw` is not a replacement for Symphony Nano.

It is a separate application with three responsibilities:

1. act as the conversational front door across multiple channels
2. act as the planning/orchestration brain that can use skills and route work
3. act as the control plane that maps work to the correct Symphony team/workflow

Symphony Nano remains responsible for:

- polling Linear
- creating per-issue workspaces
- running Codex or Claude Code in those workspaces
- driving issue execution to completion

## Key Decisions

### Keep the core in Elixir

The long-lived planner, queue consumers, state machine, Symphony integration, and dashboard should
live in Elixir/Phoenix.

Reasons:

- deep integration with Symphony Nano is easier if both runtimes are Elixir
- BEAM supervision is a better fit for the planner/control-plane side
- Phoenix LiveView is the desired dashboard stack

### Keep connectors in TypeScript sidecars

The connector layer should be implemented in TypeScript using the Vercel Chat SDK.

Reasons:

- better connector ecosystem and existing TypeScript connector code
- easier reuse of platform SDKs and existing channel code
- cleaner boundary between transport and orchestration

### Use sidecars, not embedded Node processes, as the default shape

The TypeScript runtime should be a separate service/process rather than logic embedded directly
inside the Elixir VM.

Reasons:

- crash isolation
- independent dependency management
- easier local iteration on connector code
- clearer operational boundary

### Use a queue between sidecars and core

Connector events and outbound commands should go through a durable queue rather than direct
request/response coupling.

Recommended split:

- NATS JetStream for cross-runtime message transport
- Postgres for authoritative application state
- Oban for Elixir-internal jobs and retries

### Use one external conversation session per channel thread

Each connector conversation must have its own session state.

Session identity should be scoped by:

- workspace
- connector
- bot identity
- external channel id
- external thread or conversation id

### Support multiple agents/personalities

`symphonyclaw` must support multiple bot identities and personas.

Examples:

- a planning assistant persona
- a dev-team intake persona
- a support persona
- a repo-specific agent with a dedicated channel identity

Each persona can be bound to different channels and different Symphony teams.

## Non-Goals for v1

- cross-region deployment
- marketplace-style plugin system
- multi-tenant billing
- FE/BE parallel execution inside a single Symphony issue
- direct execution of coding tasks from the connector sidecar without going through Symphony
- custom transport-specific business logic in the Elixir core

## High-Level Architecture

### Core services

1. `symphonyclaw-core` (Elixir/Phoenix)
   - planner
   - skill runner
   - session manager
   - persona router
   - Linear integration
   - Symphony integration
   - queue consumers/producers
   - dashboard and APIs

2. `symphonyclaw-connectors` (TypeScript)
   - Vercel Chat SDK based sidecar
   - Slack/Discord/Telegram adapters
   - platform-specific auth and webhook/socket handling
   - normalized event publishing
   - outbound command execution

3. `symphony-nano`
   - execution runtime for tracked engineering work

### Infrastructure

- Postgres
- NATS JetStream
- Oban
- Phoenix PubSub
- PM2 for sidecar crash recovery in dev and simple single-host deployments
- `mise` for local bootstrapping and multi-process startup

## Runtime Boundaries

### Elixir core owns

- session resolution
- agent persona selection
- skill authorization and invocation
- all durable business state
- Linear issue creation/update/status sync
- Symphony team resolution and lifecycle integration
- dashboard rendering
- queue consumption and dispatch
- audit/event history

### TypeScript sidecar owns

- connector SDKs
- webhook/socket subscriptions
- channel-specific auth
- channel-specific message formatting
- channel-specific commands such as message send, update, typing, reactions, modal flows

### Symphony owns

- issue execution after handoff
- workspace creation
- backend execution in the workspace
- implementation loops against a Linear issue

## Recommended Repo Shape

If `symphonyclaw` is a new repo:

- `apps/core`
- `apps/connectors`
- `config`
- `priv`
- `.symphony`
- `docs`

Suggested paths:

- `apps/core` for Phoenix application
- `apps/connectors` for TypeScript sidecar
- `config/symphonyclaw.toml` for runtime registry
- `.symphony/WORKFLOW.md` for the project-local Symphony workflow
- `.symphony/bootstrap.sh` for workspace bootstrap
- `docs/architecture.md` and `docs/protocol.md` for stable contracts

If `symphonyclaw` stays near Symphony Nano during incubation, the same logical boundaries should
still apply even if the directories differ.

## Primary Data Model

### Workspaces

Represents a logical org/project/environment boundary.

Fields:

- `id`
- `name`
- `slug`
- `default_persona_id`
- `default_symphony_team_id`
- `settings`

### Agent personas

Represents how a bot thinks and behaves.

Fields:

- `id`
- `name`
- `slug`
- `display_name`
- `description`
- `system_prompt`
- `voice_style`
- `allowed_skills`
- `default_response_mode`
- `default_symphony_team_id`
- `tool_policy`
- `active`

### Bot identities

Represents a real bot account on a connector.

Fields:

- `id`
- `connector`
- `external_bot_id`
- `display_name`
- `token_ref`
- `settings`
- `active`

### Channel bindings

Connects a workspace, persona, bot identity, and channel scope.

Fields:

- `id`
- `workspace_id`
- `persona_id`
- `bot_identity_id`
- `connector`
- `external_channel_id`
- `external_thread_policy`
- `allowed_modes`
- `default_symphony_team_id`
- `active`

### Sessions

Represents one ongoing external conversation.

Fields:

- `id`
- `workspace_id`
- `connector`
- `bot_identity_id`
- `persona_id`
- `external_channel_id`
- `external_thread_id`
- `external_user_id`
- `status`
- `last_message_at`
- `memory_summary`
- `current_linear_issue_id`
- `current_symphony_team_id`

### Session events

Append-only history of normalized inbound and outbound activity.

Fields:

- `id`
- `session_id`
- `direction`
- `event_type`
- `payload`
- `connector_message_id`
- `created_at`

### Symphony teams

Represents a named route into Symphony execution.

Fields:

- `id`
- `name`
- `slug`
- `repo_path`
- `workflow_path`
- `linear_project_slug`
- `dashboard_port`
- `default_backend`
- `stage_backends`
- `settings`
- `active`

### Dispatch runs

Represents a handoff from `symphonyclaw` into Symphony.

Fields:

- `id`
- `session_id`
- `persona_id`
- `symphony_team_id`
- `linear_issue_id`
- `reason`
- `status`
- `metadata`
- `created_at`
- `completed_at`

## Session Model

### Rule

One external thread or channel conversation maps to one internal session.

Examples:

- one Discord thread -> one session
- one Telegram DM -> one session
- one Slack thread in a channel -> one session
- one Slack channel without threads -> one session per channel if configured that way

### Session behavior

- the session stores conversation state and routing state
- the session can be re-opened after inactivity
- the session can accumulate multiple Symphony dispatches over time
- the session can be pinned to a persona or re-routed by policy

## Persona Model

Personas are first-class objects, not ad-hoc prompts.

Each persona should define:

- purpose
- speaking style
- allowed skills
- escalation policy
- whether it can create Linear issues
- whether it can trigger Symphony
- default Symphony team
- allowed channels
- memory policy

Example personas:

- `commander`: broad planning and orchestration
- `dev-intake`: turns user requests into engineering work
- `support`: answers questions directly and escalates only when needed
- `repo-owner`: routes only to one Symphony team/repo

## Queue Contract

### Transport choice

Use NATS JetStream for connector/core transport.

### Inbound subjects

- `connector.inbound.message`
- `connector.inbound.interaction`
- `connector.inbound.system`
- `connector.heartbeat`

### Outbound subjects

- `connector.outbound.send_message`
- `connector.outbound.update_message`
- `connector.outbound.typing`
- `connector.outbound.reaction`
- `connector.outbound.modal`

### Event envelope

Every queue message should contain:

- `event_id`
- `event_type`
- `connector`
- `workspace_slug`
- `bot_identity_slug`
- `session_key`
- `occurred_at`
- `trace_id`
- `payload`

### Delivery rules

- all inbound events are durable until acknowledged by the Elixir core
- all outbound commands are durable until acknowledged by the sidecar
- duplicate deliveries must be safe
- handlers must be idempotent by `event_id`

## Sidecar Contract

### Sidecar responsibilities

- receive platform events
- normalize them
- publish normalized events
- consume outbound commands
- execute platform API calls
- emit heartbeats and connector health status

### Recovery behavior

- PM2 autorestarts sidecar processes on crash
- sidecars emit heartbeat messages on a short interval
- Elixir marks a sidecar degraded if heartbeats stop
- queued events remain durable while a sidecar is down

### Process shape

Preferred v1 shape:

- one sidecar process for all enabled connectors in an environment
- one PM2 ecosystem definition
- one configuration source derived from `symphonyclaw.toml`

## Symphony Integration

### Handoff model

`symphonyclaw` should not directly run coding tasks in channel sessions.

Instead it should:

1. decide that a request needs tracked engineering work
2. create or update a Linear issue
3. resolve the target Symphony team from policy/config
4. ensure the matching Symphony process is running
5. let Symphony pick up the issue through its normal Linear polling loop
6. monitor status changes and report them back into the session

### What gets handed off

- Linear issue title and description
- session context summary
- persona chosen
- relevant acceptance criteria
- links back to the originating channel and session

### What stays in `symphonyclaw`

- why the work was created
- channel-side UX
- session summaries
- status updates to humans
- escalation decisions

## `symphonyclaw.toml`

The control-plane config should be authoritative for:

- workspaces
- personas
- bot identities
- connector enablement
- Symphony team registry
- channel bindings
- queue and process settings

Suggested shape:

```toml
[system]
name = "symphonyclaw"
environment = "development"

[database]
url = "$DATABASE_URL"

[queue]
nats_url = "$NATS_URL"
stream = "symphonyclaw"

[processes]
sidecar_mode = "pm2"
heartbeat_timeout_seconds = 30

[[personas]]
slug = "commander"
display_name = "Commander"
default_symphony_team = "core-platform"
allowed_skills = ["linear", "plan", "dispatch"]

[[bot_identities]]
slug = "commander-discord"
connector = "discord"
display_name = "Commander"
token_env = "DISCORD_BOT_TOKEN"

[[teams]]
slug = "core-platform"
repo_path = "/absolute/path/to/symphonyclaw"
workflow_path = "/absolute/path/to/symphonyclaw/.symphony/WORKFLOW.md"
linear_project_slug = "replace-me"
dashboard_port = 46110
default_backend = "codex"

[[channel_bindings]]
workspace = "default"
persona = "commander"
bot_identity = "commander-discord"
connector = "discord"
external_channel_id = "1234567890"
default_symphony_team = "core-platform"
```

## Dashboard Requirements

The dashboard should be Phoenix LiveView with Salad UI.

Use `mix salad.install` rather than runtime setup helpers so the components are copied locally and
fully customizable.

### Required dashboard surfaces

- system overview
- queue health
- sidecar health
- active sessions
- recent session events
- personas
- bot identities
- channel bindings
- Symphony teams
- dispatch runs
- Linear issue status
- sidecar heartbeat status
- dead-letter or failed event view

### Per-session view

Each session page should show:

- channel identity
- persona
- current mode
- recent inbound/outbound events
- linked Linear issues
- linked Symphony dispatch runs
- last known summary
- operator actions

## Developer Experience

### `mise`

Use `mise` to boot the full local stack.

Minimum local tasks:

- `mise run dev`
- `mise run dev:core`
- `mise run dev:connectors`
- `mise run dev:nats`
- `mise run dev:db`
- `mise run test`

### PM2

Use PM2 for the TypeScript sidecar in local dev and simple single-host deployments.

Minimum PM2 behavior:

- autorestart on crash
- named process
- log files
- memory restart limit
- environment-specific config

This should be treated as a process convenience layer, not the primary durability story.

### Production note

It should be possible to replace PM2 later with containers, systemd, or another supervisor without
changing the connector/core contract.

## Suggested Implementation Phases

### Phase 0: foundation

- initialize `symphonyclaw` repo shape
- add Phoenix app
- add TypeScript sidecar app
- add Postgres and NATS configuration
- add `symphonyclaw.toml`
- add `mise` tasks

### Phase 1: core skeleton

- create workspace/persona/session/team schemas
- create config loader for `symphonyclaw.toml`
- create queue producer/consumer boundary
- create health endpoints and basic dashboard shell

### Phase 2: sidecar skeleton

- bootstrap Vercel Chat SDK sidecar
- wire one connector first
- implement inbound normalization
- implement outbound command execution
- implement heartbeat publishing

### Phase 3: planner and routing

- session resolver
- persona selector
- simple skill policy
- direct-response mode
- decision engine for when to create/update a Linear issue

### Phase 4: Symphony bridge

- team registry integration
- Symphony ensure/status bridge
- dispatch run model
- create/update Linear issue flow
- report Symphony status back into sessions

### Phase 5: dashboard

- Salad UI install
- overview page
- session inspector
- queue page
- sidecar status page
- Symphony team status page

### Phase 6: hardening

- idempotency keys
- retries
- dead-letter handling
- audit logging
- permission boundaries
- connector reconnection handling

## Initial Milestone Definition

The first milestone should prove the full loop:

1. receive a message in one connector
2. create or resume a session
3. route to a persona
4. decide the request needs engineering work
5. create a Linear issue
6. ensure the mapped Symphony team is running
7. let Symphony pick up the issue
8. show the run in the dashboard
9. post updates back into the originating session

## Acceptance Criteria

### Core

- `symphonyclaw.toml` is loaded and validated
- sessions are durable in Postgres
- personas are configurable
- Symphony teams are configurable
- the queue contract is implemented with idempotent consumers

### Sidecar

- at least one connector works end-to-end
- sidecar publishes heartbeats
- sidecar restarts cleanly under PM2
- outbound commands are idempotent

### Dashboard

- LiveView dashboard renders without custom JS framework sprawl
- Salad UI is installed locally and used for the dashboard shell
- operators can inspect sessions, sidecars, queue health, and Symphony dispatches

### Symphony bridge

- `symphonyclaw` can create/update Linear work
- `symphonyclaw` can map work to a Symphony team
- Symphony status is visible from the session and dashboard

## Implementation Guidance for Symphony

When Symphony is asked to build `symphonyclaw`, it should:

1. treat this plan as the source of truth
2. preserve the Elixir-core / TypeScript-sidecar split
3. avoid collapsing everything into one runtime
4. implement the smallest end-to-end slice first
5. prefer simple, inspectable contracts over clever abstractions
6. keep channel-specific logic in the sidecar and business logic in the Elixir core
7. keep Symphony Nano as the downstream execution runtime rather than reimplementing it
