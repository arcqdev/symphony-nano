---
name: linear
description: |
  Manage Linear through the local `linear` CLI for issue reads, comments,
  state changes, relations, and raw GraphQL fallback via `linear api`.
---

# Linear CLI

Use this skill for Linear work in both Codex and Claude sessions in this repo.

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

- Use `linear issue view <identifier> --json` when you need structured issue data.
- Use `linear issue comment list <identifier>` before posting or editing workpad comments.
- Prefer `--description-file` and `--body-file` for multi-line markdown.
- Use one narrow command at a time instead of broad list operations.
- Fall back to `linear api` only when the regular CLI does not expose the needed field or mutation.

## Quick reference

### Issues

```bash
linear issue view ENG-123
linear issue view ENG-123 --json

linear issue list --all-states
linear issue list --project "Project Name"

linear issue update ENG-123 -s "In Progress"
linear issue update ENG-123 -t "New title"
linear issue update ENG-123 --description-file /tmp/desc.md
```

### Comments

```bash
linear issue comment list ENG-123
linear issue comment add ENG-123 -b "Comment text"
linear issue comment add ENG-123 --body-file /tmp/comment.md
linear issue comment update <comment-id> -b "Updated comment text"
linear issue comment update <comment-id> --body-file /tmp/comment.md
```

### Relations

```bash
linear issue relation list ENG-123
linear issue relation add ENG-123 blocked-by ENG-100
linear issue relation add ENG-123 blocks ENG-456
```

### Projects, teams, labels

```bash
linear project list
linear project view <project-id>

linear team list
linear team view <team-key>

linear label list
```

## Raw GraphQL fallback

Use `linear api` for operations the high-level CLI does not expose directly.

Examples:

```bash
linear api '{ viewer { id name email } }'
```

```bash
linear api --variable id=ENG-123 <<'GRAPHQL'
query($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
  }
}
GRAPHQL
```

```bash
linear api --variable id=ENG-123 <<'GRAPHQL'
query($id: String!) {
  issue(id: $id) {
    comments(first: 20) {
      nodes {
        id
        body
      }
    }
  }
}
GRAPHQL
```

## Symphony-specific guidance

- Use the same `linear` skill path for both Codex and Claude in this repo.
- Do not rely on a global Linear MCP server for repo workflows.
- Do not rely on Symphony's `linear_graphql` dynamic tool as the primary path.
- If an operation is unavailable through normal `linear` commands, use `linear api` before considering any other integration path.
