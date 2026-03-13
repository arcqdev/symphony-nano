# OpenClaw + Linear + Symphony Plan

## Goal

Build a dev-team workflow where:

- OpenClaw is the front door.
- Linear is the source of truth for work items.
- Symphony watches Linear and automatically executes eligible issues.
- Execution inside a single issue is sequential, not FE/BE parallel.
- Validation failures route work back to the previous responsible stage.
- Multiple issues can run in parallel.
- Each issue uses its own isolated SQLite database and workspace.

## Decisions

### Keep

- `OpenClaw` for intake and lightweight orchestration.
- `Linear` for durable issue tracking.
- `Symphony` for autonomous issue pickup and execution.
- project-local Symphony config/bootstrap files stored in each repo under `~/dev/arcqdev/`

### Avoid for v1

- FE/BE parallel execution inside one issue.
- Mission Control as the primary orchestration layer.
- Shared SQLite databases across issue runs.
- Native multi-project Symphony changes.

## Target Architecture

### Flow

1. OpenClaw receives a request like "get the dev team on this."
2. OpenClaw creates or updates a Linear issue in the correct project.
3. Symphony polls Linear and picks up eligible issues automatically.
4. Symphony runs a sequential staged workflow:
   - frontend if needed
   - backend if needed
   - full-stack integration if needed
   - initial validation
   - frontend QA only when frontend work was part of the issue
5. If validation fails, Symphony routes back to the previous responsible stage:
   - UI/design failure -> frontend
   - API/data failure -> backend
   - wiring/integration failure -> full-stack
6. When the issue reaches a terminal Linear state, OpenClaw treats the run as complete.

### Parallelism

- Parallel across issues: yes
- Parallel inside one issue: no for v1

## Linear Setup

### Required

- Create a Linear project for each repo/workstream Symphony should watch.
- Configure the expected workflow states on the relevant Linear team:
  - `Todo`
  - `In Progress`
  - `Human Review`
  - `Merging`
  - `Rework`
  - `Done`
  - `Cancelled` or `Canceled`
  - `Duplicate`
- Create a Linear API key for the operator account or service account.
- Add Jon to the relevant Linear team/project.

### Recommended

- Use a dedicated service account instead of Jon's personal account.
- Use one Symphony instance per Linear project/repo.
- Optionally set `tracker.assignee` so Symphony only picks up Jon-owned or bot-owned issues.

## Symphony Setup

### Per project

Create one `WORKFLOW.md` per project with:

- the project's `tracker.project_slug`
- the correct `workspace.root`
- repo bootstrap logic in `hooks.after_create`
- a sequential staged prompt body

### Project-local layout

All projects live under `~/dev/arcqdev/`, and Jon already knows the repo locations by project name.

Use that fact directly instead of inventing a detached global config structure.

Recommended pattern:

- keep the Symphony workflow/config files in the repo itself
- keep each project's Symphony workspaces under that same repo
- keep logs under that same repo or a repo-local hidden directory

Example for `littlebrief`:

- repo: `~/dev/arcqdev/littlebrief`
- workflow file: `~/dev/arcqdev/littlebrief/.symphony/WORKFLOW.md`
- workspaces root: `~/dev/arcqdev/littlebrief/.symphony/workspaces`
- logs root: `~/dev/arcqdev/littlebrief/.symphony/log`

This keeps each Symphony instance obviously tied to the repo Jon already expects.

### Repo-aware startup convention

Jon should start Symphony from a repo-aware wrapper or convention that maps a spoken/written project name to its known repo path.

Expected behavior:

1. resolve project name to repo path under `~/dev/arcqdev/`
2. use the repo-local Symphony workflow file for that project
3. store workspaces and logs under the same repo's `.symphony/` directory
4. expose a distinct dashboard port per project

This avoids Jon having to remember which generic Symphony instance belongs to which project.

### Polling

- Default polling is `30s`
- Sample repo currently uses `5s`
- Keep `5s` to `15s` for responsive pickup without over-polling

### Prompt responsibilities

The prompt should implement:

- scope classification before stage execution
- stage detection
- stage ordering
- validation classification
- backward routing on failure
- retry caps per stage
- workpad updates reflecting current stage and failure reason

### Stage classification rules

Before execution, classify the issue into:

- `needs_frontend`
- `needs_backend`
- `needs_integration`

Then build the stage list from that classification.

Examples:

- frontend-only:
  - frontend
  - initial validation
  - frontend QA
- backend-only:
  - backend
  - initial validation
- frontend + backend:
  - frontend
  - backend
  - full-stack integration
  - initial validation
  - frontend QA
- backend + integration but no frontend:
  - backend
  - full-stack integration
  - initial validation

Rule:

- if `needs_frontend = false`, skip frontend QA entirely
- backend-only or non-UI tasks stop at the initial validator unless a UI stage actually ran

### Not required

- No Symphony code change is needed for v1 if we stay single-project-per-instance.

## SQLite Strategy

### Rule

Never share one SQLite file across concurrent issue workers.

### Required pattern

- one workspace per issue
- one SQLite DB per workspace
- one app process per workspace when needed

### Suggested layout

- workspace: `<workspace.root>/<issue-id>`
- database: `<workspace>/ .data/dev.sqlite`

For repo-local setup, prefer:

- workspace root: `<repo>/.symphony/workspaces`
- issue workspace: `<repo>/.symphony/workspaces/<issue-id>`
- database: `<repo>/.symphony/workspaces/<issue-id>/.data/dev.sqlite`

### Bootstrap

In `hooks.after_create`:

1. clone repo into the issue workspace
2. create `.data/`
3. copy a template SQLite DB or run migrations
4. set DB env vars to the workspace-local database path

## OpenClaw Responsibilities

### Intake

- decide that a request should become tracked engineering work
- create or update a Linear issue
- store the Linear issue identifier locally if needed

### Completion tracking

OpenClaw should not use LLM turns to check status.

Use cheap polling instead:

- Linear issue state as canonical status
- optionally Symphony HTTP API for runtime detail

Completion rule:

- terminal Linear state = done

### Low-token polling rule

OpenClaw polling must be implemented as normal code, not as repeated LLM invocations.

Preferred pattern:

- a simple cron job or scheduled task
- plain HTTP requests to Symphony and/or plain Linear API requests
- straightforward `if/else` logic on returned status
- only notify or invoke an LLM when something meaningful changes

Example logic:

1. fetch current Linear state for the tracked issue
2. if state is terminal, mark the run complete
3. else fetch Symphony runtime status if extra visibility is needed
4. if status is unchanged, do nothing
5. if status changed or a failure/blocker appeared, emit a user-visible update

Rule:

- no "ask OpenClaw/Codex if it is done yet" loops
- no token spend for steady-state polling
- token spend only on intake, meaningful transitions, or explicit summaries

### Optional enhancement

If one user request should become multiple independent work items, OpenClaw can split it into multiple Linear issues so Symphony can run them in parallel.

### Suggested polling implementation

Implement a lightweight repo-local cron or scheduler that:

- tracks issue IDs created by OpenClaw
- polls every `2 minutes`
- stores the last known state locally
- short-circuits when nothing changed

This can be a minimal script with:

- request Linear issue state
- optionally request Symphony `/api/v1/<issue_identifier>`
- compare with previous status
- exit immediately if unchanged

No LLM call is needed for this path.

## Implementation Phases

### Phase 1: Single project, single repo

- Create the Linear project and workflow states
- Create service account or API key
- Configure one Symphony instance
- Write the sequential staged `WORKFLOW.md` prompt
- Verify one issue can:
  - get picked up
  - run stages
  - bounce back on validation failure
  - finish cleanly

### Phase 2: OpenClaw handoff

- Add OpenClaw logic to create/update the Linear issue
- Add cheap polling from OpenClaw to Linear and/or Symphony API
- Surface run status back to the user

### Phase 3: Multi-issue parallelism

- Verify two issues can run at once
- verify isolated workspaces
- verify isolated SQLite DBs
- verify no shared ports or shared app instances

### Phase 4: Multi-project rollout

- Run one Symphony instance per project/repo
- Standardize `WORKFLOW.md` templates
- Standardize workspace and SQLite bootstrap conventions
- Standardize a repo-local `.symphony/` layout in every project under `~/dev/arcqdev/`
- Add a Jon-facing launcher convention that resolves project names like `littlebrief` to the correct repo path

## Risks

### Prompt-only stage orchestration can drift

- Mitigation: keep stages sequential and deterministic
- Mitigation: use strict validator outcomes
- Mitigation: cap retries

### SQLite contention or corruption

- Mitigation: issue-local DB files only
- Mitigation: workspace-local app processes only

### Overloading the machine with parallel issues

- Mitigation: tune `agent.max_concurrent_agents`
- Mitigation: keep test/dev services isolated per workspace

### Multi-project complexity

- Mitigation: use one Symphony instance per project instead of extending Symphony first

## Immediate Next Steps

1. Create the Linear project and workflow states.
2. Decide whether Jon or a service account owns the Symphony API key.
3. Draft the first project-specific `WORKFLOW.md`.
4. Define the workspace-local SQLite bootstrap commands for `hooks.after_create`.
5. Add OpenClaw logic to create/update the Linear issue and poll for completion.
6. Define the repo-local `.symphony/` folder convention for projects under `~/dev/arcqdev/`.
7. Give Jon a simple project-name-to-repo startup flow so he can launch the right Symphony instance without confusion.
