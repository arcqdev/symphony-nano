#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/nano/plugins/acp-claude"

if [ ! -d "$PLUGIN_DIR/node_modules/@zed-industries/claude-agent-acp" ]; then
  echo "Installing ACP Claude wrapper dependencies in $PLUGIN_DIR" >&2
  (cd "$PLUGIN_DIR" && npm install --no-fund --no-audit)
fi

cd "$REPO_ROOT/elixir"
exec mise exec elixir@1.19 -- mix run --no-start ../nano/smoke/backend_smoke.exs
