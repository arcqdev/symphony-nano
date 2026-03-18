---
name: linear
description: |
  Manage Linear through a narrow local `linear` CLI command set for issue reads,
  compact workpad updates, and state changes.
---

# Linear CLI

Use this skill for Linear work in both Codex and Claude sessions in this repo.

Read `symphony-nano/LINEAR_GUIDELINES.md` before first use in a session and follow it strictly.

## Primary tool

Use the local `linear` CLI, authenticated with `LINEAR_API_KEY`.

On first use in a session:

```bash
linear auth login -k "$LINEAR_API_KEY"
linear auth whoami
```

If `LINEAR_API_KEY` is missing or `linear` is unavailable, treat Linear work as
blocked instead of assuming access.

## Best practices

- Use only the explicitly allowed commands in `symphony-nano/LINEAR_GUIDELINES.md`.
- Use `linear issue view <identifier> --json` when you need structured issue data.
- Use `linear issue comment list <identifier>` only when you need to find or reuse the single workpad comment.
- Prefer `--description-file` and `--body-file` for multi-line markdown.
- When `sync_workpad` is available in the current runtime, use it for workpad body syncs instead of sending large inline comment-update payloads.
- Use one narrow command at a time instead of broad list operations.
- Update the workpad once per completed stage with one compact rewrite.
- Do not post or edit Linear comments for every checklist item or small milestone.
- Do not attempt GraphQL introspection or any other undisclosed Linear operation.

## Allowed command surface

Only use the following command patterns unless `symphony-nano/LINEAR_GUIDELINES.md` is updated first.

```bash
linear issue view ENG-123 --json
linear issue comment list ENG-123
linear issue comment add ENG-123 --body-file /tmp/comment.md
linear issue comment update <comment-id> -b "Updated comment text"
linear issue comment update <comment-id> --body-file /tmp/comment.md
linear issue update ENG-123 -s "In Progress"
linear issue update ENG-123 -s "Done"
```

When available, prefer this dynamic tool for workpad syncs:

```text
sync_workpad(issue_id, file_path, comment_id?)
```

Recommended flow:

- use `linear issue comment list <identifier>` once to find or confirm the single workpad comment ID
- write the full workpad markdown to a file inside the issue workspace
- call `sync_workpad` with the Linear issue ID and that file path
- only fall back to `linear issue comment add/update --body-file` when the dynamic tool is unavailable

The `linear issue view ... --json` output is the source of truth for issue state, assignee, labels,
and other issue metadata needed for normal repo workflows.

## Compact workpad policy

- Use exactly one persistent workpad comment per issue.
- Reuse the existing workpad when present.
- Rewrite the full workpad body in one compact update after a completed stage, not after each
  checklist item.
- Prefer file-based sync via `sync_workpad` so workpad rewrites do not bloat the model context.
- Keep the workpad concise and reviewer-oriented.

## Symphony-specific guidance

- Use the same `linear` skill path for both Codex and Claude in this repo.
- Do not rely on a global Linear MCP server for repo workflows.
- Symphony does not expose a default `linear_graphql` dynamic tool in this repo.
- If you need more Linear functionality, update `symphony-nano/LINEAR_GUIDELINES.md` and this
  skill before using any new command shape.
- Do not attempt any other Linear calls.
