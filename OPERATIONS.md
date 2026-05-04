# Operations: Google Workspace MCP on Railway

## 1. What this is

A self-hosted [Google Workspace MCP](https://github.com/taylorwilsdon/google_workspace_mcp)
fork running on Railway, exposed at a public HTTPS URL, with OAuth 2.1
+ Dynamic Client Registration so `claude.ai` can attach to it as a
custom connector. Persistent OAuth state (DCR client registrations,
authorization codes, refresh-token metadata) is held on a Railway
Volume mounted at `/data`. Per-deployment scaffolding is in
`railway.json`, `Dockerfile.railway`, `bin/start.sh`, and
`DEPLOYMENT_RAILWAY.md`. No application logic was modified; everything
in this document operates the upstream codebase as-is.

> **Heads up on "Firestore".** Earlier requirements mentioned
> Firestore-backed token persistence. The upstream codebase does not
> have a Firestore backend — only `local_directory`, `gcs`,
> `memory`/`disk`/`valkey`. We use the **`disk` backend on a Railway
> Volume**. If you ever genuinely need Firestore, that's an
> application-code change (a new `AsyncKeyValue` adapter), not a
> deployment change.

---

## 2. Service identity

| Item | Value |
| --- | --- |
| Public URL | `https://googleworkspacemcp-production-abd2.up.railway.app` |
| MCP endpoint | `https://googleworkspacemcp-production-abd2.up.railway.app/mcp` |
| OAuth callback (Google must allow this) | `https://googleworkspacemcp-production-abd2.up.railway.app/oauth2callback` |
| Health endpoint | `https://googleworkspacemcp-production-abd2.up.railway.app/health` |
| GCP project | `claude-workspace-mcp` |
| Bound Google account (project owner / OAuth consent contact) | `<my gmail>` |
| Railway project / service | `<name>` → `google-workspace-mcp` |
| Volume mount | `/data` (single replica only) |

---

## 3. Environment variable reference

### Required — deploy fails or is insecure without these

| Var | What it does | What happens if it's wrong |
| --- | --- | --- |
| `GOOGLE_OAUTH_CLIENT_ID` | OAuth 2.0 client ID for the GCP Web client. | Sign-in returns `Error 401: invalid_client`. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Paired secret. | Same as above. |
| `WORKSPACE_EXTERNAL_URL` | Public URL the server advertises in OAuth metadata and uses to build redirect URIs. **Must include the `https://` scheme**, no trailing slash. | Wrong scheme → Pydantic `url_parsing` crash inside `GoogleProvider` init, container crashloops. `bin/start.sh` defensively auto-prepends `https://` if missing. Trailing slash → claude.ai can't match the resource metadata. |
| `MCP_ENABLE_OAUTH21` | Turns on the FastMCP OAuth 2.1 proxy. | Without it, claude.ai's discovery flow can't find protected-resource metadata; connector stays "Disconnected". |
| `WORKSPACE_MCP_STATELESS_MODE` | Disables on-disk credential writes outside the OAuth proxy store. Required because Railway's non-volume FS is ephemeral. | If `false`, the local credential store path activates and tokens may be written to ephemeral container storage — lost on every redeploy. |
| `WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND` | Selects the FastMCP OAuth proxy persistence backend. We use `disk`. | `memory` → DCR clients and OAuth state are lost on every restart, every user re-pairs every redeploy. Other invalid values fall back to memory silently. |
| `WORKSPACE_MCP_OAUTH_PROXY_DISK_DIRECTORY` | Path to the FileTreeStore data dir; we point it inside the volume at `/data/oauth-proxy`. | Outside `/data` → not on the volume, lost on redeploy. Pointing at a path the process can't write → `Permission denied` crash on init. |
| `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` | Allowlist of DCR redirect URIs. Must include both `https://claude.ai/api/mcp/auth_callback` and `https://claude.com/api/mcp/auth_callback`. | If unset, *any* DCR client can register *any* redirect URI — phishing risk on a public deployment. If set but missing claude.ai's callbacks, sign-in fails with "Invalid redirect URI". |
| `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` | Stable encryption key for OAuth proxy state at rest **and** the signing key for JWTs handed to claude.ai. | If unset, FastMCP derives one from `GOOGLE_OAUTH_CLIENT_SECRET` — meaning a client-secret rotation silently invalidates every JWT and the encrypted disk state. Set once, never rotate, treat as a long-lived secret. |

### Recommended

| Var | What it does |
| --- | --- |
| `PYTHONUNBUFFERED=1` | Flushes stdout/stderr immediately so Railway runtime logs show boot progress and tracebacks live. Set in `Dockerfile.railway`, but harmless to set explicitly too. |
| `LOG_LEVEL=INFO` | Default. Bump to `DEBUG` during incidents only — `DEBUG` logs can include URL-parameter-bearing tokens. |

### Do not set (and why)

| Var | Why not |
| --- | --- |
| `OAUTHLIB_INSECURE_TRANSPORT` | We're on HTTPS. The codebase only auto-sets it for `localhost` redirect URIs (`auth/google_auth.py:498-504`). Setting it weakens transport checks for no reason. |
| `WORKSPACE_MCP_CREDENTIAL_STORE_BACKEND`, `WORKSPACE_MCP_GCS_BUCKET`, `GOOGLE_APPLICATION_CREDENTIALS*` | In stateless mode (`auth/google_auth.py:725`) the credential store is bypassed entirely. These vars are silently ignored and only invite future confusion. |
| `PORT` | Railway injects it; the app reads it (`main.py:379`). Setting it manually fights Railway's router. |
| `WORKSPACE_MCP_HOST` | Defaults to `0.0.0.0`, which is what Railway's healthcheck and external proxy expect. |

---

## 4. Redeploy procedure

Railway is wired to the fork's `main` branch with autodeploy enabled.

```bash
git checkout main
git pull
# make changes...
git commit -am "..."
git push origin main
```

That triggers a build on Railway. Watch progress in **Railway →
Deployments → (newest)**. Build logs appear there; runtime logs (the
ones with `[start.sh]`, FastMCP banner, etc.) are under the **Logs**
tab.

Manual redeploy without a code change: Railway → Deployments →
**Redeploy** on the latest deployment.

Rollback: Railway → Deployments → click any older successful deploy
→ **Redeploy**. There is no `git revert` requirement.

---

## 5. Rotate OAuth credentials

### Rotating the OAuth client secret

1. **Google Cloud Console → APIs & Services → Credentials.** Open the
   Web OAuth client.
2. **Add Secret** (you can keep the old one active during overlap).
3. In Railway, update `GOOGLE_OAUTH_CLIENT_SECRET` to the new value.
4. **Critical:** if `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` is
   *unset*, FastMCP is deriving the JWT signing key from the client
   secret you just rotated → every existing claude.ai session is now
   dead. Confirm this var is set explicitly before rotating, or
   accept that all users must re-auth.
5. Once the new secret is live and verified working, delete the old
   secret in GCP.

### Rotating the OAuth client itself (entirely new client ID)

Same procedure but update both `GOOGLE_OAUTH_CLIENT_ID` and
`GOOGLE_OAUTH_CLIENT_SECRET`. Re-add the redirect URI
`https://<service>.up.railway.app/oauth2callback` on the new client
before swapping. All existing user sessions die — they re-auth via
claude.ai's standard flow.

### Rotating `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY`

Don't, unless you accept the same blast radius:
- All issued JWTs become invalid → every claude.ai session must
  re-auth.
- Encrypted entries on disk in `/data/oauth-proxy` become
  un-decryptable → wipe the volume after rotating, or the proxy will
  log decrypt warnings indefinitely.

If rotation is forced (key suspected leaked):
1. Generate new key: `python -c "import secrets; print(secrets.token_urlsafe(64))"`.
2. Set the new value in Railway.
3. SSH into the service or use Railway's shell, then
   `rm -rf /data/oauth-proxy/*` (or just delete the Volume and
   recreate it).
4. Redeploy. Tell users to reconnect their connector in claude.ai.

---

## 6. Recover if the OAuth proxy volume is wiped

> The original brief mentioned "Firestore data is wiped" — we don't
> use Firestore. The equivalent failure here is the Railway Volume at
> `/data` being deleted, corrupted, or losing its encrypted contents
> (which happens implicitly when `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY`
> changes — the Fernet wrapper can no longer decrypt).

Symptoms in logs:
```
[ERROR] Failed to decrypt entry: ...
Failed to initialize FastMCP GoogleProvider: ...
```

Recovery:
1. Wipe the volume cleanly:
   - Railway → service → **Settings → Volumes** → detach + delete →
     create a new 1 GB volume → mount at `/data`. (Or shell in and
     `rm -rf /data/oauth-proxy/*`, but cleaner to recreate.)
2. Confirm `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` is set and
   stable in env vars.
3. Redeploy. The directory `/data/oauth-proxy/` is recreated by
   `bin/start.sh` on first boot.
4. **Each user must reconnect** the MCP server in claude.ai →
   Settings → Connectors. They go through the Google sign-in flow
   again. Their Google authorization on the GCP side is unaffected
   — the only thing lost is the local DCR/refresh-token mapping.

There is no backup story for `/data/oauth-proxy`. The data is
short-lived OAuth state; it's cheap to regenerate by re-auth.

---

## 7. Adding a new Google API scope

Two cases.

### Case A — extending an already-enabled service

E.g. enabling Tasks write access (the codebase already has
`gmail`, `drive`, `calendar`, `docs`, `sheets`, `chat`, `forms`,
`slides`, `tasks`, `search` enabled by default; see
`fastmcp_server.py:157-168`). Per-service scopes are defined in
`auth/scopes.py` (`TOOL_SCOPES_MAP`).

1. **GCP**: APIs & Services → Library → enable the API if not
   already enabled.
2. **GCP OAuth consent screen**: add the scope so it's listed for
   end users on the consent prompt (Testing-mode apps need this for
   the scope to be requestable).
3. **Code**: if it's a new scope on an existing tool, edit
   `auth/scopes.py` to add it to that tool's scope list. Push to
   `main`.
4. **Users re-auth** in claude.ai so the new scope shows up on
   their next consent — Google will not silently grant a new scope
   to an existing token.

### Case B — adding a brand-new tool / service

Out of scope for an ops doc — that's an upstream feature, not an
operational task. The pattern is: a new module under e.g.
`gnewservice/`, scopes added to `auth/scopes.py`, registered in
`fastmcp_server.py`'s import block. See how `gtasks/` is wired.

---

## 8. The 60-second smoke test

```bash
SERVICE=https://googleworkspacemcp-production-abd2.up.railway.app

# 1. Health (~ 5s)
curl -fsS "$SERVICE/health" | jq
# expected: {"status":"healthy","service":"workspace-mcp",...}

# 2. OAuth metadata (~ 5s)
curl -fsS "$SERVICE/.well-known/oauth-protected-resource" | jq .resource
# expected: "https://googleworkspacemcp-production-abd2.up.railway.app/mcp"

# 3. MCP endpoint requires auth (~ 5s)
curl -i -X POST \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"initialize","id":1}' \
  "$SERVICE/mcp" | head -20
# expected: HTTP/1.1 401 Unauthorized
#           www-authenticate: Bearer resource_metadata="..."
```

If all three pass, the deployment is live and OAuth-protected. Open
claude.ai → Connectors → confirm your existing connection still
lists tools.

If #1 fails: app is crashing — check Railway runtime logs.
If #2 fails: server up but OAuth not initialized — check
`MCP_ENABLE_OAUTH21`, `GOOGLE_OAUTH_CLIENT_ID`/`_SECRET`, and
`WORKSPACE_EXTERNAL_URL`.
If #3 returns 200 instead of 401: OAuth enforcement off — check
`MCP_ENABLE_OAUTH21=true` and `WORKSPACE_MCP_STATELESS_MODE=true`.

---

## 9. Bus-factor table

| Credential / asset | Where it lives | Who can recreate it | Notes |
| --- | --- | --- | --- |
| Google OAuth client ID | GCP project → Credentials → Web client | Project owner / anyone with `roles/iam.serviceAccountKeyAdmin` (effectively project IAM admin) | Free to regenerate. Existing user sessions survive only if you keep the old client active during overlap. |
| Google OAuth client secret | Same | Same | Can be rotated independently of the client ID — see §5. |
| `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` | Railway env var | Anyone with Railway project access | **Cannot be regenerated without invalidating all sessions.** Treat like a long-lived production secret. Back it up to a password manager. |
| `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` | Railway env var | Anyone with Railway project access | Static list; recreating it from this doc is trivial. |
| Railway service config (`railway.json`, `Dockerfile.railway`, `bin/start.sh`) | Git repo `main` branch | Anyone with push to the fork | Reproduces deterministically from `main`. |
| Railway Volume contents (`/data/oauth-proxy/*`) | Volume only — no backup | Cannot be recreated | Short-lived OAuth state. Loss = forced re-auth for every user, no permanent damage. |
| GCP project ownership | Google account `<fill in>` | Only that account | If this account is lost, the OAuth client and consent screen go with it. **Add a second project owner** (a backup Google account or a GCP-managed group) before considering this done. |
| Railway account access | `<fill in: account email>` | Only that account | Same advice — invite a backup user as Owner under Railway's Team settings. |

---

## 10. Cost summary

Order-of-magnitude only. Always confirm against the providers' current
pricing pages before budgeting.

| Component | Plan | Cost |
| --- | --- | --- |
| Railway service (CPU/RAM) | Hobby ($5/mo flat fee includes $5 of usage) or Pro (usage-based) | A small Python container with this workload typically runs **$5–15 / month**, dominated by RAM-time. Idle most of the day, brief spikes during MCP calls. |
| Railway Volume (1 GB) | Usage-based | **~$0.25 / GB-month**, so **~$0.25 / month** at 1 GB. |
| Railway egress | First slice free, then per-GB | Negligible — MCP traffic is small JSON. |
| GCP OAuth (consent screen + Web client) | Free | $0. |
| Google Workspace API quotas | Per-API free tier; per-user-per-second limits | $0 within normal personal use. Heavy automation can hit per-second limits but not billing. |
| **Firestore** | **N/A — not in use** | $0. We persist on the Railway Volume; there is no Firestore database. |

**Expected total: roughly $5–20 / month**, almost entirely Railway.
If you outgrow a single replica, the optional Redis (Valkey) backend
adds another small Railway plugin charge — see `DEPLOYMENT_RAILWAY.md`
§3 Option B.
