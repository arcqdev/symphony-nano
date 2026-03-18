# LINEAR_GUIDELINES.md

Use the local `linear` CLI as the only Linear integration path for normal repo workflows.

## Allowed functionality

The current allowed Linear feature set is intentionally narrow:

- read one issue by identifier with structured JSON
- inspect issue assignee and labels from that issue payload
- list comments for the current issue to find or reuse the single workpad comment
- create the single workpad comment when missing
- update the existing workpad comment in place
- move the issue between workflow states already used by the repo
- sync workpad bodies through the dedicated `sync_workpad` dynamic tool when available

## Allowed command patterns

Use only these command shapes:

```bash
linear auth login -k "$LINEAR_API_KEY"
linear auth whoami
linear issue view ENG-123 --json
linear issue comment list ENG-123
linear issue comment add ENG-123 --body-file /tmp/comment.md
linear issue comment update <comment-id> --body-file /tmp/comment.md
linear issue update ENG-123 -s "In Progress"
linear issue update ENG-123 -s "Done"
linear issue update ENG-123 -s "Rework"
linear issue update ENG-123 -s "BLOCKED - requires human"
```

## Workpad policy

- Use exactly one persistent `## Codex Workpad` comment per issue.
- Reuse the existing workpad when present.
- Do not update the workpad after every checkbox or minor milestone.
- Finish the current stage, then write one compact update that reflects the completed stage.
- Compact updates are full comment rewrites, not differential edits.
- When the runtime exposes `sync_workpad`, prefer it over inline multi-line comment update payloads.
- Keep the markdown body in a workspace file, then call `sync_workpad(issue_id, file_path, comment_id?)`.
- Keep the workpad focused on current status, current plan, validation summary, blockers, and final proof.

## Scope limits

- Do not use any other `linear` commands.
- Do not use `linear api`.
- Do not use GraphQL introspection.
- Do not perform broad list operations across projects, teams, or labels.
- If you need additional Linear functionality, update this file and `symphony-nano/.codex/skills/linear/SKILL.md` first.
