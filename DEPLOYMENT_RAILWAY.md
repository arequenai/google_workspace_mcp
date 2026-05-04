# Deploying Google Workspace MCP to Railway

This guide walks through deploying this server as a remote MCP on
[Railway](https://railway.com), reachable from `claude.ai` at
`https://<service>.up.railway.app/mcp` with full OAuth 2.1.

> **Token persistence — read this first.** The README mentions Cloud Run
> with the `gcs` credential-store backend. **That backend is not used on
> Railway** in the configuration recommended here, because we run in
> *stateless mode* (required for a multi-tenant remote MCP behind
> `claude.ai`). In stateless mode, `auth/google_auth.py` skips the
> credential store entirely (line 725) and all OAuth state — including
> refresh-token metadata — is held by the FastMCP OAuth proxy's
> `client_storage`. The supported `client_storage` backends are
> `memory`, `disk`, and `valkey`. **There is no native Firestore
> backend**; the closest *persistent* options are `disk` (this guide,
> using a Railway Volume) or `valkey` (a Redis plugin). A Firestore
> backend would require an application-code change (a new
> `AsyncKeyValue` adapter) which is out of scope for this PR.

---

## 1. Prerequisites

- A Railway account with a project + service.
- A Google Cloud project (only the OAuth client is needed — no GCS bucket
  or service account required for this deployment).
- Your fork of this repository connected to the Railway service.

---

## 2. Google Cloud — OAuth 2.0 Client Setup

These steps create the OAuth client that Google's authorization server
uses when users sign in through Claude.

1. **Open the Google Cloud Console** → select your project → **APIs &
   Services → Library** and enable each API you intend to use:
   Gmail API, Google Drive API, Google Calendar API, Google Docs API,
   Google Sheets API, Google Slides API, Google Forms API, Google Tasks
   API, Google Chat API, Google People API, Custom Search API.

2. **APIs & Services → OAuth consent screen.**
   - User type: **External** (unless your account is in a Workspace
     organization and you only need internal users).
   - Fill in app name, support email, developer contact.
   - While the app is in *Testing* mode, add every Google account that
     should be able to sign in as a **Test user**. Without this, sign-in
     returns `Error 403: access_denied`.

3. **APIs & Services → Credentials → Create Credentials → OAuth client
   ID.**
   - Application type: **Web application** (Desktop client types do not
     work for a hosted MCP).
   - Authorized redirect URI:
     ```
     https://<your-service>.up.railway.app/oauth2callback
     ```
     This codebase overrides FastMCP's default `/auth/callback` and
     always uses `/oauth2callback` (`auth/oauth_config.py:112`). Adding
     `/auth/callback` as well is harmless but unnecessary.
   - Save and copy the **Client ID** and **Client secret**.

---

## 3. Railway — Persistent storage for OAuth state

Without persistent storage, every Railway redeploy invalidates all
in-flight OAuth state and registered DCR clients. Two options:

### Option A — Railway Volume + `disk` backend (recommended, simplest)

This deployment uses **`Dockerfile.railway`** (referenced from
`railway.json`), which is the upstream `Dockerfile` minus the
`USER app` directive. The reason: Railway Volumes are mounted as
**root with mode 755**, so the running process must be root in order
to create the OAuth-proxy directory inside the volume on first boot.
The upstream `Dockerfile` (used by docker-compose, helm, Cloud Run,
smithery, etc.) keeps its `USER app` hardening — only Railway runs
as root, and only because of the volume-ownership constraint.

The start command in `railway.json` defensively runs
`mkdir -p "$WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY"` before
launching the server.

1. In the Railway service: **Settings → Volumes → New Volume.** Mount
   path: `/data`. Size: 1 GB is plenty.
2. In §4 below set:
   ```
   WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND=disk
   WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY=/data/oauth-proxy
   ```
3. Constraint: a Railway Volume is bound to a **single replica**. If you
   ever scale beyond one instance, switch to Option B.

### Option B — Railway Redis plugin + `valkey` backend (multi-replica)

Use this if you need horizontal scaling. **Note**: the upstream
`Dockerfile` does *not* install the `valkey` extra. To use this option
you must either fork the Dockerfile to add `--extra valkey` to the
`uv sync` line, or override the Railway start command to install it at
boot — see "Installing the valkey extra" at the end of this document.

---

## 4. Railway — Create and configure the service

1. **New Project → Deploy from GitHub repo** → pick your fork. Railway
   detects `railway.json` and `Dockerfile` automatically.
2. **Settings → Networking → Generate Domain.** This gives you the
   `https://<service>.up.railway.app` URL. Copy it.
3. Update the OAuth client's authorized redirect URI in Google Cloud
   (§2 step 3) to match the Railway domain.
4. Add a Volume per §3 Option A (or Redis per Option B).
5. **Variables** tab → set the variables below.

### Required environment variables

| Variable | Value | Notes |
| --- | --- | --- |
| `GOOGLE_OAUTH_CLIENT_ID` | from §2 | Google OAuth Web client ID. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | from §2 | Google OAuth Web client secret. |
| `WORKSPACE_EXTERNAL_URL` | `https://<service>.up.railway.app` | Public HTTPS URL Railway issues. The server uses this to build redirect URIs and OAuth metadata. **No trailing slash.** |
| `MCP_ENABLE_OAUTH21` | `true` | Enables the OAuth 2.1 proxy required for `claude.ai`. |
| `WORKSPACE_MCP_STATELESS_MODE` | `true` | Required: Railway's filesystem (outside the volume) is ephemeral, and `claude.ai` requires per-request bearer tokens. |
| `WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND` | `disk` | Persists DCR client registrations, OAuth transactions, and refresh-token metadata. With Option A above, this writes to your Railway Volume. |
| `WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY` | `/data/oauth-proxy` | Path inside the Volume mount. |
| `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` | `https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback` | DCR redirect-URI allowlist. **Required** to prevent phishing on a public deployment — without this, any client can register any redirect URI. |
| `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` | a long random string | Stable encryption key for OAuth proxy state at rest, **and** the key used to sign JWTs handed to `claude.ai`. Generate with `python -c "import secrets; print(secrets.token_urlsafe(64))"`. Set it **once and never rotate** unless you want to invalidate every existing session. If you don't set it, FastMCP derives one from `GOOGLE_OAUTH_CLIENT_SECRET` — meaning a client-secret rotation silently invalidates everything. |

### Recommended environment variables

| Variable | Value | Notes |
| --- | --- | --- |
| `PYTHONUNBUFFERED` | `1` | Cleaner Railway logs. |
| `LOG_LEVEL` | `INFO` | Bump to `DEBUG` only when troubleshooting. |

### Variables you do NOT need

- `OAUTHLIB_INSECURE_TRANSPORT` — leave unset. The codebase only sets it
  automatically for `localhost`/`127.0.0.1` redirect URIs
  (`auth/google_auth.py:498-504`); on HTTPS Railway URLs it is unused.
- `WORKSPACE_MCP_CREDENTIAL_STORE_BACKEND`, `WORKSPACE_MCP_GCS_BUCKET`,
  `GOOGLE_APPLICATION_CREDENTIALS*` — irrelevant in stateless mode (see
  the box at the top of this document).
- `PORT` — Railway injects this automatically; the app reads it
  (`main.py:379`).
- `WORKSPACE_MCP_HOST` — defaults to `0.0.0.0`, which is correct for
  Railway.

---

## 5. Deploy and verify

1. Trigger a deploy.
2. Watch the deploy logs. You should see:
   ```
   FastMCP Cloud: OAuth 2.1 stateless defaults already satisfied
   OAuth 2.1: Using FileTreeStore for FastMCP OAuth proxy client_storage (directory=/data/oauth-proxy)
   Uvicorn running on http://0.0.0.0:<PORT>
   ```
3. **Health check** (the `/health` endpoint is registered at
   `core/server.py:562`):
   ```bash
   curl -i https://<service>.up.railway.app/health
   # → HTTP/1.1 200 OK
   ```
4. **OAuth metadata:**
   ```bash
   curl -s https://<service>.up.railway.app/.well-known/oauth-protected-resource | jq
   ```
   Should reference your service URL.
5. **MCP endpoint** — the FastMCP default for streamable-http is exactly
   `/mcp` (no trailing slash; FastMCP `settings.py:264`,
   `streamable_http_path: str = "/mcp"`). In **stateless mode the route
   only accepts POST and DELETE**
   (`fastmcp/server/http.py:325-338`), so a plain GET returns
   **405 Method Not Allowed** — that is expected and means the route is
   live. To exercise auth, send a POST without a token:
   ```bash
   curl -i -X POST \
     -H "Accept: application/json, text/event-stream" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"initialize","id":1}' \
     https://<service>.up.railway.app/mcp
   # → 401 Unauthorized + WWW-Authenticate: Bearer with resource_metadata
   ```
   That 401 is the correct unauthenticated response and is what tells
   `claude.ai` where to start the OAuth dance.
6. **Connect from claude.ai:**
   - Settings → Connectors → Add custom connector.
   - URL: `https://<service>.up.railway.app/mcp` (with the `/mcp`).
   - Approve the Google scopes; the connector should then list its
     tools.

---

## 6. Common errors

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Error 400: redirect_uri_mismatch` from Google | The Web OAuth client doesn't list the Railway URL | Add `https://<service>.up.railway.app/oauth2callback` to the Web client's Authorized redirect URIs and wait ~1 min for propagation. |
| `Error 403: access_denied` from Google | Consent screen still in Testing and the user isn't on the test-user list | Add the user under OAuth consent screen → Test users, or publish the app. |
| `claude.ai` shows "Invalid redirect URI" after consent | `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` doesn't include Claude's callbacks | Set to `https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback`. |
| Server logs `Disk client_storage requested but disk dependencies are not installed` | Image was built without the `disk` extra | `Dockerfile.railway` (and the upstream `Dockerfile`) include `--extra disk`. If you forked, restore that flag. |
| `Failed to initialize FastMCP GoogleProvider: [Errno 13] Permission denied: '/data/oauth-proxy'` | The image switched to `USER app` but the Railway Volume at `/data` is owned by root | Confirm `railway.json` sets `dockerfilePath: Dockerfile.railway` (which runs as root). The upstream `Dockerfile` has `USER app` and will hit this error on Railway. |
| Tokens / DCR clients lost across redeploys | `WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY` not pointing inside a Railway Volume mount | Mount a Volume at `/data` and set the directory under it. |
| Random sign-out after a deploy | `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` was rotated, or was unset and `GOOGLE_OAUTH_CLIENT_SECRET` changed | Set a stable random value once and don't rotate. |
| Health check fails immediately after deploy | App crashed on boot | Open the deploy logs; usually a missing required env var. |
| Health check fails on cold start | Boot took > 60 s | Bump `healthcheckTimeout` in `railway.json`. |
| `claude.ai` connects but no tools appear | `WORKSPACE_EXTERNAL_URL` doesn't exactly match the public URL | Check it's `https://`, no trailing slash, no port. |
| `405 Method Not Allowed` on `GET /mcp` | Stateless mode disables GET on `/mcp` (server-initiated SSE makes no sense without sessions) | This is correct. Use POST as in §5 step 5. |

---

## 7. Reference: what `railway.json` configures

- Builder: `DOCKERFILE`, `dockerfilePath: Dockerfile.railway` — a
  thin variant of the upstream `Dockerfile` that omits `USER app` so
  the process can write to a root-owned Railway Volume.
- Start command: `/app/bin/start.sh` — a tiny shell script in the
  repo (`bin/start.sh`). It runs `mkdir -p` on the OAuth-proxy
  directory (idempotent, fine for first boot of a fresh Volume) and
  then `exec uv run main.py --transport streamable-http`. Kept as a
  script so the `startCommand` in `railway.json` is a single
  executable path — Railway has been observed to exec the
  `startCommand` directly without wrapping it in `sh -c`, which
  silently breaks any shell features like `${VAR:-default}`, `&&`,
  or `exec`.
- Health check: `GET /health`, 60 s timeout.
- Restart policy: on failure, up to 5 retries.

No application code is modified — only deployment scaffolding.

---

## 8. Installing the `valkey` extra (Option B only)

The upstream `Dockerfile` installs `--extra disk` but **not**
`--extra valkey`. If you choose Option B in §3, do one of:

- **Fork the Dockerfile**: change the `uv sync` line to
  `RUN uv sync --frozen --no-dev --extra disk --extra valkey`.
  This is the cleanest option — the `valkey` package is already pinned
  in `uv.lock`, so the build stays reproducible.
- **Or override the Railway start command** in `railway.json` to install
  the extra at boot:
  ```
  "startCommand": "uv sync --frozen --no-dev --extra disk --extra valkey && exec uv run main.py --transport streamable-http"
  ```
  This adds a few seconds of cold-start latency on each deploy but
  avoids editing the Dockerfile.

Then add a Railway Redis plugin and set:

```
WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND=valkey
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_HOST=${{Redis.RAILWAY_PRIVATE_DOMAIN}}
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_PORT=${{Redis.REDIS_PORT}}
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_PASSWORD=${{Redis.REDIS_PASSWORD}}
```
