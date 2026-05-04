# Deploying Google Workspace MCP to Railway

This guide walks through deploying this server as a remote MCP on
[Railway](https://railway.com), reachable from `claude.ai` at
`https://<service>.up.railway.app/mcp` with full OAuth 2.1.

> **Note on token persistence.** The README mentions Cloud Run; this guide
> covers Railway. The codebase ships with two credential-storage backends:
> `local_directory` (ephemeral on Railway — lost on every redeploy) and
> `gcs` (Google Cloud Storage, persistent, authenticated via a Google
> service account). **There is no native Firestore backend.** GCS is the
> closest supported equivalent for "Google-Cloud-backed token persistence
> via service account" and is what this guide uses. If you specifically
> need Firestore, that would require a new `CredentialStore` subclass —
> outside the scope of deployment scaffolding.

---

## 1. Prerequisites

- A Railway account with a project + service.
- A Google Cloud project (can be the same one you use for OAuth).
- The `gcloud` CLI (only for the one-time setup steps below).
- Your fork of this repository connected to the Railway service.

---

## 2. Google Cloud — OAuth 2.0 Client Setup

These steps create the OAuth client that Google's authorization server
will use when users sign in through Claude.

1. **Open the Google Cloud Console** → select your project → **APIs &
   Services → Library** and enable each of the APIs you intend to use:
   Gmail API, Google Drive API, Google Calendar API, Google Docs API,
   Google Sheets API, Google Slides API, Google Forms API, Google Tasks
   API, Google Chat API, Google People API, Custom Search API.

2. **APIs & Services → OAuth consent screen.**
   - User type: **External** (unless your account is in a Workspace
     organization and you only need internal users).
   - Fill in app name, support email, developer contact.
   - Add the scopes you want exposed (the server requests scopes
     dynamically per tool — adding them here only affects the consent
     screen list).
   - While the app is in *Testing* mode, add every Google account that
     should be able to sign in as a **Test user**. Without this, sign-in
     returns `Error 403: access_denied`.

3. **APIs & Services → Credentials → Create Credentials → OAuth client
   ID.**
   - Application type: **Web application** (required — Desktop client
     types do not work for a hosted MCP).
   - Authorized redirect URIs — add **both**:
     ```
     https://<your-service>.up.railway.app/oauth2callback
     https://<your-service>.up.railway.app/auth/callback
     ```
     (The first is the legacy callback; the second is the OAuth 2.1
     proxy callback. Adding both avoids surprises if the deployment
     toggles modes.)
   - Save and copy the **Client ID** and **Client secret** — you'll
     paste these into Railway in step 4.

---

## 3. Google Cloud — Token Persistence (GCS bucket + service account)

Without this, every Railway redeploy invalidates all user tokens.

```bash
# Choose names
export PROJECT_ID="my-gcp-project"
export BUCKET="my-workspace-mcp-tokens"          # must be globally unique
export SA_NAME="workspace-mcp-railway"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Create the bucket (uniform bucket-level access recommended)
gcloud storage buckets create "gs://${BUCKET}" \
  --project="${PROJECT_ID}" \
  --location=us-central1 \
  --uniform-bucket-level-access

# Create the service account
gcloud iam service-accounts create "${SA_NAME}" \
  --project="${PROJECT_ID}" \
  --display-name="Workspace MCP (Railway)"

# Grant object-level access on just this bucket
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectUser"

# Generate a JSON key (you'll paste this into Railway)
gcloud iam service-accounts keys create sa-key.json \
  --iam-account="${SA_EMAIL}"
```

Open `sa-key.json` and copy the **entire JSON contents** — you'll paste
it into Railway as `GOOGLE_APPLICATION_CREDENTIALS_JSON` in the next
step. **Delete the local file afterwards.**

> Optional CMEK hardening: if you enabled a default KMS key on the
> bucket, also grant `roles/storage.bucketViewer` to the service account
> and set `WORKSPACE_MCP_GCS_REQUIRE_CMEK=true` in Railway. See the
> README's "GCS-Backed Storage" section.

---

## 4. Railway — Create and configure the service

1. **New Project → Deploy from GitHub repo** → pick your fork. Railway
   detects `railway.json` and `Dockerfile` automatically.
2. **Settings → Networking → Generate Domain.** This gives you the
   `https://<service>.up.railway.app` URL. Copy it.
3. Go back to step 2 of the Google Cloud setup and **make sure the
   redirect URIs match the domain Railway just generated.**
4. **Variables** tab → paste in the variables below.

### Required environment variables

| Variable | Value | Notes |
| --- | --- | --- |
| `GOOGLE_OAUTH_CLIENT_ID` | from §2 | Google OAuth client ID |
| `GOOGLE_OAUTH_CLIENT_SECRET` | from §2 | Google OAuth client secret |
| `WORKSPACE_EXTERNAL_URL` | `https://<service>.up.railway.app` | Public HTTPS URL Railway issues. The server uses this to build redirect URIs and resource metadata. **Must not have a trailing slash.** |
| `MCP_ENABLE_OAUTH21` | `true` | Enables the OAuth 2.1 proxy required for `claude.ai`. |
| `WORKSPACE_MCP_STATELESS_MODE` | `true` | Disables on-disk credential writes — required because Railway's filesystem is ephemeral. |
| `WORKSPACE_MCP_CREDENTIAL_STORE_BACKEND` | `gcs` | Persist user tokens in GCS instead of the local disk. |
| `WORKSPACE_MCP_GCS_BUCKET` | bucket name from §3 | The bucket you created. |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | full contents of `sa-key.json` | The Google client library reads this when running on Railway. See "Service-account JSON on Railway" below. |
| `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` | `https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback` | DCR redirect-URI allowlist. Required to prevent phishing on a public deployment. |
| `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` | a long random string | Stable encryption key for OAuth proxy state. Generate with `python -c "import secrets; print(secrets.token_urlsafe(64))"`. Set this **once and never rotate** unless you're willing to invalidate all sessions. |

### Recommended environment variables

| Variable | Value | Notes |
| --- | --- | --- |
| `WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND` | `memory` | OAuth proxy state. `memory` is fine for a single Railway replica; tokens themselves are persisted to GCS via the credential store. For multi-replica setups, attach a Railway Redis plugin and use `valkey` (see below). |
| `OAUTHLIB_INSECURE_TRANSPORT` | *(unset)* | Leave **unset** in production. The Dockerfile does not set it. |
| `PYTHONUNBUFFERED` | `1` | Cleaner Railway logs. |
| `LOG_LEVEL` | `INFO` | Bump to `DEBUG` only when troubleshooting. |

### Multi-replica option (optional)

If you scale Railway replicas above 1, the in-memory OAuth proxy state
will not be shared. Add a **Railway → New → Database → Redis** plugin
and set:

```
WORKSPACE_MCP_OAUTH_PROXY_STORAGE_BACKEND=valkey
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_HOST=${{Redis.RAILWAY_PRIVATE_DOMAIN}}
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_PORT=${{Redis.REDIS_PORT}}
WORKSPACE_MCP_OAUTH_PROXY_VALKEY_PASSWORD=${{Redis.REDIS_PASSWORD}}
```

(Railway's reference-variable syntax wires this up at deploy time.)

### Service-account JSON on Railway

The Google client libraries look for `GOOGLE_APPLICATION_CREDENTIALS`
(a **path**), not the JSON directly. Two options:

1. **Recommended:** install the `Railway` JSON-to-file pattern by
   setting both:
   - `GOOGLE_APPLICATION_CREDENTIALS_JSON` = full JSON contents
   - `GOOGLE_APPLICATION_CREDENTIALS` = `/tmp/gcp-sa.json`

   …and add this one-liner to the start command in `railway.json`:
   `printenv GOOGLE_APPLICATION_CREDENTIALS_JSON > "$GOOGLE_APPLICATION_CREDENTIALS" && uv run main.py --transport streamable-http`.

2. Or use Railway's "shared variables / file mounts" UI to mount the
   JSON file directly and set `GOOGLE_APPLICATION_CREDENTIALS` to the
   mount path.

Pick whichever fits your workflow; both are equivalent at runtime.

---

## 5. Deploy and verify

1. Trigger a deploy (push to the branch Railway tracks, or hit
   "Deploy" in the dashboard).
2. Watch the deploy logs. You should see:
   ```
   FastMCP Cloud: OAuth 2.1 stateless defaults already satisfied
   GCSCredentialStore initialized with bucket=...
   Uvicorn running on http://0.0.0.0:<PORT>
   ```
3. **Health check:**
   ```bash
   curl -i https://<service>.up.railway.app/health
   # → HTTP/1.1 200 OK
   ```
4. **OAuth metadata:**
   ```bash
   curl -s https://<service>.up.railway.app/.well-known/oauth-protected-resource | jq
   ```
   You should see a JSON document referencing your service URL.
5. **MCP endpoint:**
   ```bash
   curl -i https://<service>.up.railway.app/mcp
   # → 401 with WWW-Authenticate: Bearer + resource_metadata pointer
   ```
   A 401 here is the **correct** response for an unauthenticated
   request — it tells Claude where to start the OAuth dance.
6. **Connect from claude.ai:**
   - Settings → Connectors → Add custom connector.
   - URL: `https://<service>.up.railway.app/mcp`
   - Claude will discover the OAuth metadata, register itself via DCR,
     and redirect you through Google sign-in. Approve the scopes; the
     connector should then list its tools.

---

## 6. Common errors

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Error 400: redirect_uri_mismatch` from Google | The Web OAuth client doesn't list the Railway URL | Add `https://<service>.up.railway.app/oauth2callback` **and** `.../auth/callback` to the Web client's Authorized redirect URIs and wait ~1 min for propagation. |
| `Error 403: access_denied` from Google | Consent screen still in Testing and the user isn't on the test-user list | Add the user under OAuth consent screen → Test users, or publish the app. |
| `claude.ai` shows "Invalid redirect URI" after consent | `WORKSPACE_MCP_ALLOWED_CLIENT_REDIRECT_URIS` doesn't include Claude's callbacks | Set to `https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback`. |
| Server logs `GCSCredentialStore requires a bucket name` | `WORKSPACE_MCP_GCS_BUCKET` not set | Set the variable; redeploy. |
| Server logs `403 ... does not have storage.objects.create access` | Service account missing IAM role on the bucket | Re-run the `add-iam-policy-binding` command in §3. |
| Server logs `could not find default credentials` | `GOOGLE_APPLICATION_CREDENTIALS` not pointing at a readable file | Re-check the file-write start command in §4 ("Service-account JSON on Railway"). |
| Tokens lost across redeploys | Backend still set to `local_directory` | Set `WORKSPACE_MCP_CREDENTIAL_STORE_BACKEND=gcs` and supply bucket + SA. |
| Random sign-out after deploys | `FASTMCP_SERVER_AUTH_GOOGLE_JWT_SIGNING_KEY` rotated or unset (defaulted to client secret which changed) | Set a stable random value once and don't rotate. |
| Health check failures in Railway | App crashed on boot | Open the deploy logs; usually a missing required env var. |
| `claude.ai` connects but no tools appear | Auth succeeded but Bearer token isn't being sent on `tools/list` | Re-check `MCP_ENABLE_OAUTH21=true` and `WORKSPACE_MCP_STATELESS_MODE=true`. Also confirm `WORKSPACE_EXTERNAL_URL` matches the actual public URL exactly (no trailing slash, `https`, no port). |

---

## 7. Reference: what `railway.json` configures

- Builder: `DOCKERFILE` — Railway uses the repo's `Dockerfile` as-is.
- Start command: `uv run main.py --transport streamable-http` — overrides
  the Dockerfile `CMD` so Railway's `$PORT` is honored (the app reads
  `PORT` directly).
- Health check: `GET /health` (timeout 30s).
- Restart policy: on failure, up to 5 retries.

No application code is modified — only deployment scaffolding.
