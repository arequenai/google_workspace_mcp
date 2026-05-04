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

# Hand control to uv. exec() so signals propagate cleanly to PID 1.
exec uv run main.py --transport streamable-http
