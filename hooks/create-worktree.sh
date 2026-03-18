#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s\n' "[symphony-worktree] $*"
}

workspace="$(pwd)"
issue_id="$(basename "${workspace}")"
branch_prefix="${SYMPHONY_WORKTREE_BRANCH_PREFIX:-issue/}"
issue_branch="${branch_prefix}${issue_id}"
base_branch="${SYMPHONY_WORKTREE_BASE_BRANCH:-main}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_repo_path="${SYMPHONY_SOURCE_REPO_PATH:-$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null || true)}"

if [[ -z "${source_repo_path}" || ! -d "${source_repo_path}" ]]; then
  log "Falling back to URL bootstrap for source repo is required"
  source_repo_url="${SYMPHONY_SOURCE_REPO_URL:-}"

  if [[ -z "${source_repo_url}" ]]; then
    log "SYMPHONY_SOURCE_REPO_PATH or SYMPHONY_SOURCE_REPO_URL must be provided"
    exit 1
  fi

  cache_dir="${SYMPHONY_SOURCE_REPO_BASE_DIR:-$HOME/.cache/symphony-source-repos}"
  sanitized_url="$(printf '%s' "${source_repo_url}" | tr '/:.@' '___')"
  source_repo_path="${cache_dir}/${sanitized_url}"

  if [[ ! -d "${source_repo_path}" ]]; then
    mkdir -p "${cache_dir}"
    log "Cloning ${source_repo_url} to ${source_repo_path}"
    git clone "${source_repo_url}" "${source_repo_path}"
  fi
fi

if ! git -C "${source_repo_path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Source repo is not a valid git worktree: ${source_repo_path}"
  exit 1
fi

log "Preparing workspace ${workspace} from ${source_repo_path}"

git -C "${source_repo_path}" fetch --all --prune --tags

if git -C "${source_repo_path}" show-ref --verify --quiet "refs/remotes/origin/${base_branch}"; then
  base_ref="origin/${base_branch}"
else
  base_ref="${base_branch}"
fi

refresh_existing_workspace() {
  if ! git -C "${workspace}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "Existing workspace is not a valid git checkout: ${workspace}"
    exit 1
  fi

  git -C "${workspace}" reset --hard
  git -C "${workspace}" clean -fd
  git -C "${workspace}" checkout -B "${issue_branch}" "${base_ref}"
  git -C "${workspace}" reset --hard "${base_ref}"
  git -C "${workspace}" clean -fd

  if [[ -x "${workspace}/bin/setup" ]]; then
    "${workspace}/bin/setup"
  fi

  log "Workspace refreshed: ${workspace} (branch ${issue_branch} @ ${base_ref})"
}

if git -C "${workspace}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  refresh_existing_workspace
  exit 0
fi

if git -C "${source_repo_path}" show-ref --verify --quiet "refs/heads/${issue_branch}"; then
  worktree_ref="${issue_branch}"
elif git -C "${source_repo_path}" show-ref --verify --quiet "refs/remotes/origin/${issue_branch}"; then
  worktree_ref="origin/${issue_branch}"
else
  worktree_ref="${base_ref}"
fi

if ! git -C "${source_repo_path}" worktree add -f -b "${issue_branch}" "${workspace}" "${worktree_ref}"; then
  if ! git -C "${source_repo_path}" worktree add -f "${workspace}" "${worktree_ref}"; then
    log "Failed to create worktree for ${workspace}"
    exit 1
  fi

  if [[ "${worktree_ref}" == "${base_branch}" ]]; then
    git -C "${workspace}" checkout -B "${issue_branch}" "${worktree_ref}"
  fi
fi

git -C "${workspace}" checkout -B "${issue_branch}" "${base_ref}" >/dev/null 2>&1 || true
git -C "${workspace}" reset --hard "${base_ref}" >/dev/null 2>&1 || true
git -C "${workspace}" clean -fd >/dev/null 2>&1 || true

if [[ -x "${workspace}/bin/setup" ]]; then
  "${workspace}/bin/setup"
fi

log "Workspace prepared: ${workspace} (branch ${issue_branch})"
