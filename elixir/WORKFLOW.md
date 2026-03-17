---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "2cb9b6f4ab27"
  assignee: me
  human_review_state: "BLOCKED - requires human"
  active_states:
    - Todo
    - In Progress
    - Rework
    - BLOCKED - requires human
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate

polling:
  interval_ms: 10000

workspace:
  root: /Users/eddie/dev/arcqdev/.symphony-worktrees

hooks:
  after_create: |
    bash /Users/eddie/dev/arcqdev/symphonyclaw/.symphony/bootstrap.sh
  timeout_ms: 180000

agent:
  backend: codex
  stage_backends:
    reviewer-engineer: claude-code
  stage_models:
    implementer-engineer: gpt-5.4
    reviewer-engineer: sonnet
  stage_reasoning_efforts:
    implementer-engineer: medium
  max_concurrent_agents: 4
  max_turns: 12
  max_input_tokens: 1000000

codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  model: gpt-5.4
  reasoning_effort: medium
  approval_policy: never

acp:
  backends:
    claude-code:
      command: claude-agent-acp
      env:
        CLAUDE_CODE_EXECUTABLE: ~/.local/bin/claude
      model: sonnet

server:
  port: 46110
---

You are working on `symphonyclaw`, the root project shell. Work on the full repository checked out in
the issue workspace, not just `symphony-nano`.

Follow the repository instructions in this order before making implementation decisions:

1. `AGENTS.md`
2. `plan2.0.md`
3. `docs/developer-site/src/content/docs/architecture/front-door-and-sidecars.md`
4. the current repository structure and relevant implementation files
5. if you touch `symphony-nano`, read `symphony-nano/SPEC.md` first
6. if you change runtime behavior in `symphony-nano`, read `symphony-nano/elixir/README.md` too

Core constraints:

- keep SymphonyClaw narrow on purpose
- Elixir owns orchestration; everything else is a replaceable seam
- do not turn the root project into another OpenClaw
- keep Discord, Telegram, Slack, and similar channel concerns in shell-owned sidecars
- do not add sandbox complexity to the core
- keep boundaries explicit, inspectable, and easy to replace

Project objective:

- make SymphonyClaw the orchestration shell around a strong coding harness
- keep the front-door planner and connector architecture in the root repo
- preserve `symphony-nano` as the current execution implementation while clarifying what belongs in the shell
- prefer changes that clarify a boundary, remove an assumption, or push a concern out of core

Execution rules:

- work only inside the provided issue workspace
- treat the root repo as authoritative for docs and architecture direction
- when touching both root-level project code/docs and `symphony-nano`, keep the separation clear
- update docs/config/examples when behavior or architecture meaning changes

Completion bar:

- implementation matches the touched scope
- relevant validation for the touched area is run before handoff
- docs/config stay aligned with the resulting behavior
