# Claude Code Project Memory

This repository uses shared repo-local skills under `.codex/skills/`.
Claude Code should treat those skill files as the project's shared task playbooks.

When a task clearly matches one of these skills, open and follow the corresponding file:

- `.codex/skills/commit/SKILL.md`
- `.codex/skills/debug/SKILL.md`
- `.codex/skills/land/SKILL.md`
- `.codex/skills/linear/SKILL.md`
- `.codex/skills/pull/SKILL.md`
- `.codex/skills/push/SKILL.md`

Important distinction:

- Skills are instructions, not capabilities by themselves.
- For Linear work in this repo, use the local `linear` CLI through `.codex/skills/linear/SKILL.md`.
- This repo does not rely on a global Linear MCP server for normal workflow execution.
- If `linear` or `LINEAR_API_KEY` is unavailable in the current runtime, treat Linear operations as blocked instead of assuming access.

Core repo guidance:

- Follow `WORKFLOW.md` for stage routing, workpad behavior, and ticket lifecycle rules.
- Follow `elixir/AGENTS.md` for Elixir implementation constraints when working in `elixir/`.
- Keep changes narrow and preserve upstream-friendly structure.
- Do not assume global tools are available unless the current runtime exposes them.
