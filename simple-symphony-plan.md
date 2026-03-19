# Simple Symphony Plan

Status: proposed

## Goal

Replace the current long-session, workpad-heavy workflow with a simpler serial workflow:

- one main repo checkout
- one ticket branch at a time
- no containers
- no git worktrees
- no parallel execution
- specialized workers with short-lived sessions
- one durable plan file per ticket
- Linear kept as the tracker
- human review retained as the escape hatch

## Core Principles

- Elixir remains the orchestrator runtime.
- Workers are disposable sessions, not workflow engines.
- The orchestrator should stay small and mechanical.
- The plan file is the durable working record.
- Linear tracks ticket state, not active implementation memory.
- Validation loops are script-driven.
- Validator always runs at the end unless explicitly excluded.
- Commit and push happen at the end of a successful run.

## What We Are Removing

- containerized execution
- git worktree management
- parallel worker execution
- shared rolling transcript across stages
- Linear workpad as the active source of truth
- tracker updates during implementation loops
- transcript-heavy stage handoffs

## What We Are Keeping

- Elixir orchestrator
- ACP-based worker launching
- specialized worker profiles
- Linear ticket intake and state transitions
- repo-owned workflow configuration
- human review fallback

## Runtime Model

The runtime flow should be:

1. poll Linear for an eligible ticket
2. switch the main repo checkout to the ticket branch
3. create or load `docs/features/plan-{ticket}.md`
4. determine the ordered stage list
5. launch the first worker
6. run the mechanical fix-and-test loop for that stage
7. move to the next worker if needed
8. run validator at the end
9. if validator passes, commit and push
10. update Linear and finish

If validator fails, or if the run hits a hard limit:

- write the failure into the plan file
- add one Linear comment
- move the issue to the human review or rework path
- stop the run
- let a fresh orchestrator run pick the ticket back up later

## Orchestrator Responsibilities

The orchestrator should only:

- read the ticket and workflow config
- create or load the plan file
- decide the ordered stage list
- launch one worker at a time
- tell the worker which plan section it owns
- log stage start and stage end
- run configured checks after each worker exits
- run the mechanical retry loop for the same stage
- route to the next stage
- always route to validator unless excluded
- finalize on success
- route to human review on hard failure

The orchestrator should not:

- implement code
- do deep repo reasoning beyond lightweight planning
- summarize long logs for workers
- manage a shared transcript
- ask workers to manage workflow state

## Worker Model

Each worker is single-purpose and disposable.

Workers should:

- read the ticket packet
- read the plan file
- own exactly one named plan section
- complete the work for that stage
- update only their checklist, notes, files changed, and checks
- exit with a compact structured artifact

Workers should not:

- reroute the workflow
- manage tracker state
- manage retry policy
- maintain cross-stage memory outside the plan file

## Worker Profiles

### Design

Purpose:

- create or update brand guidance when missing
- own Paper MCP interactions
- produce design artifacts for UI work

Expected outputs:

- Paper doc or design reference
- updated Design section in the plan file
- compact artifact

### Frontend

Purpose:

- implement approved UI
- consume design artifacts when present

Expected outputs:

- code changes
- updated Frontend section in the plan file
- compact artifact

### Backend

Purpose:

- implement domain, API, data, and test changes

Expected outputs:

- code and test changes
- updated Backend section in the plan file
- compact artifact

### Integration

Purpose:

- fix contracts, boundaries, and cross-layer wiring

Expected outputs:

- code changes across boundaries
- updated Integration section in the plan file
- compact artifact

### Growth

Purpose:

- write product, landing page, onboarding, and growth-channel copy

Expected outputs:

- copy artifacts or source text updates
- updated Growth section in the plan file
- compact artifact

### Validator

Purpose:

- scrutinize whether the task is actually complete
- run final targeted checks
- report pass or fail

Expected outputs:

- updated Validator section in the plan file
- final pass or fail artifact

Default posture:

- read-only in intent
- no code edits unless explicitly allowed in workflow config

## Plan File

Each ticket gets one durable plan file:

- `docs/features/plan-{ticket}.md`

This file is the durable shared context between disposable worker sessions.

The orchestrator owns:

- stage order
- run state
- current stage
- attempt counts
- stage log

Workers own only their section:

- checklist
- notes
- files changed
- checks run
- concise summary

Suggested plan template:

```md
# Plan ENG-123

## Task
Short task summary.

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Stage Order
1. backend
2. frontend
3. integration
4. validator

## Run State
- Branch: ticket/ENG-123
- Current stage: backend
- Current attempt: 1
- Status: in_progress

## Stage Log
- 2026-03-19T10:00:00Z orchestrator started
- 2026-03-19T10:02:00Z backend started

## Design
### Checklist
- [ ] Complete design work
### Notes
- None yet.
### Files Changed
- None yet.
### Checks
- None yet.

## Backend
### Checklist
- [ ] Complete backend work
### Notes
- None yet.
### Files Changed
- None yet.
### Checks
- None yet.

## Frontend
### Checklist
- [ ] Complete frontend work
### Notes
- None yet.
### Files Changed
- None yet.
### Checks
- None yet.

## Integration
### Checklist
- [ ] Complete integration work
### Notes
- None yet.
### Files Changed
- None yet.
### Checks
- None yet.

## Growth
### Checklist
- [ ] Complete growth work
### Notes
- None yet.
### Files Changed
- None yet.
### Checks
- None yet.

## Validator
### Checklist
- [ ] Review completion
- [ ] Record final pass or fail
### Notes
- None yet.
### Checks
- None yet.
```

## Worker Artifact Contract

Each worker should return a small artifact, for example:

```json
{
  "owner": "backend",
  "status": "needs_fix",
  "files_changed": [
    "backend/src/user/updateBillingEmail.ts",
    "backend/test/updateBillingEmail.test.ts"
  ],
  "checks": [
    {
      "command": "pnpm test updateBillingEmail",
      "result": "failed",
      "failures": [
        "updateBillingEmail rejects malformed addresses"
      ]
    }
  ],
  "summary": "Persistence path added; one validation test still fails."
}
```

Allowed statuses:

- `done`
- `needs_fix`
- `blocked`
- `failed`

## Fix-And-Test Loop

This loop is mechanical and orchestrator-owned.

After a worker exits, the orchestrator runs the configured checks for that stage.

If checks fail:

1. capture only:
   - failing command
   - failing test names
   - first stack trace per failure
   - changed files
   - plan file path
   - owned stage section
2. launch the same worker type again
3. ask it only to fix the reported failures and update its plan section
4. rerun the checks
5. stop after the configured max attempt count

Rules:

- no raw multi-thousand-line logs in worker context
- no rerouting during the loop
- same worker owns the repair loop unless human review is triggered

## Validator Failure Model

Validator should always run at the end unless explicitly excluded.

If validator passes:

- orchestrator commits
- orchestrator pushes
- orchestrator updates Linear to done

If validator fails:

- validator updates the Validator section with failure reasons
- orchestrator posts one Linear comment with a concise failure summary
- orchestrator moves the issue to rework or human review
- orchestrator stops
- a fresh orchestrator run later re-reads the ticket and routes it to the right repair stage

This keeps validator failure as a clean run boundary instead of turning it into an in-memory recovery saga.

## Human Review

Human review stays in the system as the fallback path.

Human review should be triggered when:

- max fix attempts are exhausted
- max token budget is reached
- required tooling or auth is unavailable
- validator reports a failure that should be reviewed before more automated changes
- the orchestrator cannot safely determine the next repair stage

Human review should be a coarse state transition, not an interactive pause inside a live worker loop.

## Linear Model

Linear remains in use, but narrowly.

Keep Linear for:

- ticket intake
- ticket state transitions
- final success comment
- validator or run failure comment

Do not use Linear for:

- active implementation memory
- live workpad syncing
- iterative cross-stage handoff notes

Recommended state usage:

- `Todo` -> `In Progress` when run starts
- `In Progress` -> `Done` on successful validator pass
- `In Progress` -> `Rework` or human review state on validator or loop failure

## Dashboard

The dashboard should become more useful for the simpler serial runtime.

It should optimize for answering:

- what ticket is currently active
- what stage is running right now
- which stages are already complete
- what failed most recently
- how many repair attempts have happened
- how much token budget has been consumed by Codex versus Claude

### Primary Dashboard View

For the active run, show:

- ticket identifier and title
- current branch
- current stage
- overall run status
- current attempt count
- ordered stage list with statuses:
  - pending
  - in_progress
  - passed
  - failed
  - skipped
- last stage event timestamp
- whether the run is in normal execution, fix loop, validator, or human review

### Stage Timeline

The dashboard should include a compact stage timeline, for example:

- `design` -> passed
- `backend` -> passed
- `frontend` -> in_progress
- `integration` -> pending
- `validator` -> pending

This can be rendered as either:

- a vertical event log with timestamps, or
- a horizontal progress tracker with the current stage highlighted

The important part is that completed versus pending stages are immediately visible.

### Token Usage

Token usage should be shown distinctly for Codex and Claude.

Do not collapse all usage into one total.

For each provider/backend, show:

- input tokens
- output tokens
- total tokens
- percentage of configured budget consumed
- cost estimate if available

Suggested grouping:

- Codex usage
- Claude usage
- overall total

Suggested stage-level visibility:

- active stage token usage by current worker
- cumulative run token usage by provider

This makes it possible to see whether token pressure is coming from:

- repeated Codex repair loops
- expensive Claude design or writing stages
- validator churn

### Run Detail Panel

Each run detail view should show:

- ticket info
- plan file path
- stage order
- current stage owner
- files changed so far
- latest check command and result
- latest validator result
- latest human review reason if present

### Failure Visibility

When a stage fails or enters human review, the dashboard should make the reason obvious.

Show:

- failed stage
- failed command
- concise failure summary
- current retry count
- whether the next action is retry, validator stop, or human review

### Data Sources

The dashboard should read from orchestrator-owned runtime state, not from worker transcripts.

Preferred sources:

- orchestrator run state
- stage event log
- latest worker artifact
- plan file metadata
- token accounting from Codex and Claude sessions

### MVP Dashboard Scope

For the first pass, the dashboard should include:

- one active ticket panel
- stage progress list
- current status and attempt count
- latest failure summary
- distinct Codex and Claude token usage panels

Nice-to-have later:

- historical run list
- per-stage duration charts
- per-provider cost trends
- validator failure history

## Workflow Config

The runtime should move from a prose-heavy `WORKFLOW.md` toward a typed workflow config, for example
`workflow.ts`.

That config should define:

- worker profiles
- stage order rules
- stage-specific checks
- retry limits
- validator behavior
- human review behavior
- plan file path template
- Linear settings

`WORKFLOW.md` can remain as a short human-readable guide, but the machine-owned source of truth
should be typed and declarative.

## Initial MVP Decisions

For the first implementation:

- serial execution only
- no containers
- no worktrees
- main repo checkout only
- one active ticket at a time
- branch per ticket
- commit and push only at the end
- validator enabled by default
- human review enabled as fallback
- Linear retained
- plan file required for every ticket

## Implementation Order

1. Add the new typed workflow config.
2. Add plan file creation and update helpers for `docs/features/plan-{ticket}.md`.
3. Split plan ownership between orchestrator and workers.
4. Add a serial stage runner.
5. Add the mechanical fix-and-test loop per stage.
6. Add validator routing and failure handling.
7. Update the dashboard for serial stage progress and distinct Codex versus Claude token accounting.
8. Retain Linear only for intake and coarse state changes.
9. Remove worktree, container, and parallel execution assumptions from the active runtime path.

## Final Position

Simple Symphony should be:

- serial
- repo-local
- stage-based
- plan-file-driven
- artifact-based
- validator-ended
- Linear-backed
- human-review-safe

The orchestrator dispatches.
Workers execute.
Scripts validate.
Validator scrutinizes.
Linear tracks outcomes.
