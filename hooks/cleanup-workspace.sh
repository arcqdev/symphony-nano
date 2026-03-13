#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "[symphony-worktree] $*"
}

workspace="$(pwd)"
workspace_root="${SYMPHONY_WORKSPACE_ROOT:-$(dirname "${workspace}")}"

if ! git -C "${workspace}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Skipping cleanup; ${workspace} is not a git checkout"
  exit 0
fi

log "Cleaning worktree for ${workspace}"

common_dir="$(git -C "${workspace}" rev-parse --path-format=absolute --git-common-dir)"
repo_git_dir="${common_dir%/worktrees/*}"
source_repo_root="$(dirname "${repo_git_dir}")"

git -C "${workspace}" worktree remove --force "${workspace}" || true

if [[ -n "${source_repo_root}" && -d "${source_repo_root}" && -d "${workspace_root}" ]]; then
  while IFS= read -r worktree_path; do
    [[ -z "${worktree_path}" ]] && continue
    if [[ "${worktree_path}" == "${workspace_root}"/* && "${worktree_path}" != "${workspace}" ]]; then
      log "Removing sibling worktree ${worktree_path}"
      git -C "${source_repo_root}" worktree remove --force "${worktree_path}" || true
    fi
  done < <(git -C "${source_repo_root}" worktree list --porcelain | awk '/^worktree / { print $2 }')
fi

GIT_DIR="${repo_git_dir}" git worktree prune --expire=now || true

log "Worktree cleanup completed for ${workspace}"
