#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "[symphony-worktree] $*"
}

workspace="$(pwd)"
issue_id="$(basename "${workspace}")"
branch_prefix="${SYMPHONY_WORKTREE_BRANCH_PREFIX:-issue/}"
issue_branch="${branch_prefix}${issue_id}"

if ! git -C "${workspace}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Skipping worktree sync; ${workspace} is not a git checkout"
  exit 0
fi

current_branch="$(git -C "${workspace}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [[ "${current_branch}" == "HEAD" ]]; then
  current_branch=""
fi

git -C "${workspace}" fetch --all --prune --tags

if git -C "${workspace}" show-ref --verify --quiet "refs/heads/${issue_branch}"; then
  target_ref="${issue_branch}"
elif git -C "${workspace}" show-ref --verify --quiet "refs/remotes/origin/${issue_branch}"; then
  target_ref="origin/${issue_branch}"
else
  target_ref=""
fi

if [[ -n "${target_ref}" ]]; then
  if [[ "${current_branch}" != "${issue_branch}" && "${current_branch}" != "${target_ref}" ]]; then
    if [[ "${target_ref}" == origin/* ]]; then
      git -C "${workspace}" switch --detach "${target_ref}"
    else
      git -C "${workspace}" switch "${target_ref}"
    fi
  fi

  git -C "${workspace}" pull --ff-only
else
  log "No issue-specific branch ${issue_branch}; keeping existing checked-out branch"
fi

log "Workspace synced: ${workspace} (branch=${current_branch:-detached})"
