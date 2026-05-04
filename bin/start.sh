#!/bin/sh
# Railway entrypoint. Kept as a script so railway.json's startCommand
# is a single executable path with no shell-expansion or && chaining
# (Railway has been observed to exec startCommand directly without
# wrapping it in `sh -c`, which silently kills any shell features).

set -eu

# Ensure the OAuth-proxy disk-store directory exists. Idempotent so
# first-boot of a freshly mounted Railway Volume just works.
DISK_DIR="${WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY:-/data/oauth-proxy}"
mkdir -p "$DISK_DIR"

# Defensive: WORKSPACE_EXTERNAL_URL must include a scheme. Railway's
# dashboard displays the domain without one, which is an easy footgun
# that surfaces as a hard-to-decode pydantic url_parsing error deep in
# the FastMCP GoogleProvider init. Auto-prepend https:// and warn
# loudly if the user set just the bare domain.
if [ -n "${WORKSPACE_EXTERNAL_URL:-}" ]; then
  case "$WORKSPACE_EXTERNAL_URL" in
    http://*|https://*)
      ;;
    *)
      echo "[start.sh] WARN: WORKSPACE_EXTERNAL_URL='$WORKSPACE_EXTERNAL_URL' is missing a scheme; auto-prepending https://" >&2
      WORKSPACE_EXTERNAL_URL="https://$WORKSPACE_EXTERNAL_URL"
      export WORKSPACE_EXTERNAL_URL
      ;;
  esac
fi

# Boot diagnostics so a silent crash leaves a trail in Railway logs.
echo "[start.sh] PORT=${PORT:-unset} HOST=${WORKSPACE_MCP_HOST:-0.0.0.0}"
echo "[start.sh] DISK_DIR=$DISK_DIR"
echo "[start.sh] WORKSPACE_EXTERNAL_URL=${WORKSPACE_EXTERNAL_URL:-unset}"
echo "[start.sh] python: $(/app/.venv/bin/python --version 2>&1)"

# Skip `uv run` and exec the synced venv's interpreter directly. uv run
# does dependency resolution work on every invocation that we don't
# need at runtime (the venv was built with `uv sync --frozen` already).
exec /app/.venv/bin/python main.py --transport streamable-http
