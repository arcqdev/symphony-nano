# Token Reduction Through Explicit Orchestration

Status: proposed

## Goal

Reduce token usage and improve reliability by moving orchestration out of long-lived model sessions
and into deterministic Elixir runtime behavior.

This is not a proposal to remove specialized workers. It is a proposal to stop letting workers own
workflow management.

## Core Shift

Current mental model:

- multiple agents with responsibilities
- some orchestration emerges from prompts and session continuity
- long-running sessions accumulate workflow context and token cost

Proposed mental model:

- Elixir is the always-on orchestrator
- model sessions are disposable workers
- workers may still be specialized by stage or capability
- orchestration, retries, lifecycle, and routing live outside the worker

Short version:

- not agentic orchestration
- orchestrated agents

## Why

The token problem is not only prompt length. It is also duplicated reasoning:

- workers re-explain runtime policy to themselves
- stage handoffs require transcript-heavy continuity
- orchestration logic leaks into prompts
- long-lived sessions become fragile and expensive

Moving orchestration into Elixir lowers token pressure by:

- keeping durable state outside the transcript
- starting fresh worker sessions with bounded task packets
- making retries and stage transitions runtime decisions
- reducing the amount of workflow policy repeated in `WORKFLOW.md`

## What Stays The Same

- `WORKFLOW.md` remains the repo-owned workflow contract
- stage-aware routing can still select different backends/models
- workers can still be specialized for `frontend`, `backend`, `integration`, or other stages
- tracker, memory, skills, dashboards, and hooks remain seams

## What Changes

The orchestrator becomes the sole owner of:

- issue dispatch
- claim and release
- workspace lifecycle
- stage transitions
- retry and backoff
- token budget enforcement
- human review routing
- worker/backend/model selection

Workers become bounded execution units:

- receive a task packet
- operate inside a prepared workspace
- update code and work artifacts
- return a structured outcome

## Existing Alignment In Symphony Nano

This direction is already partially present:

- `elixir/lib/symphony_elixir/orchestrator.ex` already owns polling and runtime state
- `elixir/lib/symphony_elixir/agent_runner.ex` already separates execution from orchestration
- `elixir/lib/symphony_elixir/stage_routing.ex` already supports stage-aware backend selection
- `elixir/lib/symphony_elixir/agent_runner/stage_run.ex` already has stage execution boundaries
- `elixir/lib/symphony_elixir/workspace.ex` already exposes lifecycle hooks

This should be treated as a boundary cleanup, not a rewrite.

## Durable Runtime State

The orchestrator should persist a compact handoff packet outside any model session.

Suggested fields:

- issue id
- issue identifier
- workspace path
- worker host
- current stage
- selected backend
- branch and base branch
- attempt number
- last worker outcome
- compact workpad or handoff summary
- relevant artifacts or validation summary

This durable packet is what allows a new worker session to resume work without depending on a
long-lived conversational thread.

## Worker Contract

Workers should be disposable and bounded.

Suggested input contract:

- issue snapshot
- workspace path
- branch context
- current stage
- acceptance criteria
- compact handoff packet
- stage-specific constraints

Suggested output contract:

- `done`
- `blocked`
- `needs_followup`
- `retryable_failure`

Optional structured fields:

- summary
- changed areas
- validation status
- blocker reason
- suggested next stage
- handoff notes

## Specialized Workers Still Fit

This proposal does not require a single worker profile.

A clean model is:

- the orchestrator classifies or routes the issue
- the orchestrator selects the worker/backend/model for the current stage
- the selected worker executes the bounded task
- the orchestrator decides what happens next

Example:

1. issue becomes eligible
2. orchestrator routes to `frontend`
3. orchestrator prepares workspace and branch state
4. orchestrator starts a fresh frontend worker session
5. worker performs UI work and returns structured outcome
6. orchestrator decides whether to continue, retry, route onward, or hand off

The frontend worker does frontend work. It does not own orchestration policy.

## Lifecycle Hooks

Symphony Nano already has coarse hooks:

- `after_create`
- `before_run`
- `after_run`
- `before_remove`

Those should evolve into explicit lifecycle hooks with `pre` and `post` surfaces.

Suggested lifecycle namespaces:

- `workspace.create`
- `workspace.remove`
- `run.start`
- `run.finish`
- `stage.start`
- `stage.finish`
- `tracker.transition`
- `git.prepare`
- `git.finalize`

Suggested resolution order:

1. global hook
2. stage hook
3. worker-profile hook

Each hook should receive the same runtime context:

- issue
- workspace path
- worker host
- stage
- backend
- attempt number
- branch
- last outcome

This makes it possible to add pre/post behavior for nearly every deterministic lifecycle event
without pushing that behavior into model prompts.

## `WORKFLOW.md` Boundary

`WORKFLOW.md` should stay mostly agent-facing.

Keep in `WORKFLOW.md`:

- coding standards
- stage-specific execution guidance
- validation expectations
- blocker behavior
- worker output expectations

Move out of `WORKFLOW.md` into typed runtime behavior:

- polling
- retries and backoff
- claim logic
- workspace preparation policy
- token enforcement
- tracker state transitions
- branch preparation and cleanup policy

Rule of thumb:

- if it is deterministic state-machine logic, it should not live in prompt prose
- if it requires model judgment, it belongs in `WORKFLOW.md`

## Reliability Model

The orchestrator should always be running as software, not as a persistent model conversation.

Preferred runtime posture:

- long-lived Elixir orchestrator
- short-lived worker sessions
- durable handoff state between sessions

This improves reliability:

- worker disconnects are cheap
- restarts are easier to recover from
- transcript continuity is no longer the critical path

## Frontend Stage Example

1. issue is eligible
2. orchestrator routes it to the `frontend` stage
3. `pre` hooks run:
   - `run.start`
   - `stage.start`
   - optional `git.prepare`
4. orchestrator starts a fresh frontend worker session
5. worker edits UI, runs checks, and returns a structured outcome
6. `post` hooks run:
   - `stage.finish`
   - optional artifact collection
   - optional `git.finalize`
7. orchestrator transitions state:
   - next stage
   - retry
   - blocked
   - done

## Recommended Refactor Order

1. Add a durable run packet / handoff packet outside session transcripts.
2. Tighten worker outputs into a structured result contract.
3. Move stage transitions and retries fully under orchestrator control.
4. Expand current hooks into explicit lifecycle `pre` and `post` hooks.
5. Trim `WORKFLOW.md` so it contains worker guidance rather than orchestration policy.

## Final Position

Symphony Nano should move toward:

- explicit orchestration in Elixir
- disposable specialized workers
- durable runtime state outside model transcripts
- hooks around deterministic lifecycle events
- a narrower `WORKFLOW.md` focused on execution guidance

This keeps the core aligned with the repository goal:

- Elixir owns orchestration
- everything else is a seam
