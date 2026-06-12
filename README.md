# LocalSend self-hosted

Orchestration layer for a self-hosted [LocalSend](https://localsend.org)
deployment: the static web client and the WebRTC signaling server, both
running in Docker behind your existing reverse proxy (Traefik / Apache /
nginx / etc.), with optional coturn for STUN+TURN.

The two app repos are tracked as submodules of forks pinned to specific
commits, so a clone gives you a known-good combination of versions.

## Layout

```
.
├── compose.example.yaml      → copy to compose.yaml, edit for your env
├── turnserver.example.conf       → copy to turnserver.conf, edit if you want to tune coturn
├── .env.example              → copy to .env, set FQDN / TURN secret / etc.
├── docs/
│   └── coturn-apt-deployment.md   → alternative: coturn under apt + LE IP cert
├── localsend-server/  (submodule)  → Rust WebRTC signaling server
└── localsend-web/     (submodule)  → Nuxt static web client
```

## Quickstart

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/tracyhatemice/localsend.git
cd localsend
```

If you already cloned without the flag:

```bash
git submodule update --init --recursive
```

### 2. Configure

```bash
cp .env.example .env
cp compose.example.yaml compose.yaml
cp turnserver.example.conf turnserver.conf
```

Edit `.env`:

| Var | Required | Notes |
|---|---|---|
| `FQDN` | yes | Public hostname (e.g. `example.org`) |
| `BASE_PATH` | no | Sub-path to serve the app under. Default `/send`. Set to `/` for domain-root. |
| `TRAEFIK_NETWORK` | no | Docker network your existing Traefik is on. Default `traefik`. |
| `CERTRESOLVER` | no | Traefik ACME resolver name. Default `letsencrypt`. |
| `ICE_SERVER_FQDN` | no | Hostname of your TURN server. Defaults to `FQDN`. |
| `STUN_URL` | no | e.g. `stun:${ICE_SERVER_FQDN}:3478`. Leave empty to skip self-hosted STUN. |
| `TURN_URL` | no | e.g. `turn:${ICE_SERVER_FQDN}:3478`. Leave empty to skip TURN. |
| `TURN_AUTH_SECRET` | when TURN enabled | Random secret. Generate: `openssl rand -base64 48` |

### 3. Build & run

```bash
docker compose up -d --build
```

Expose ports at your reverse proxy:
- HTTPS termination on `${FQDN}` → forward to `localsend-web` (port 80 in container)
- Same hostname, path `${BASE_PATH}/v1/*` → forward to `localsend-signaling` (port 3000)
- If using coturn from the compose stack: UDP+TCP **3478** and UDP **49160-49200** open on your host firewall (both v4 and v6)

The `compose.example.yaml` ships with Traefik labels that handle the path
routing automatically. Apache / nginx users: see the example vhost in the
commit history or wire equivalent rules manually.

### 4. Verify

```bash
# Web reachable
curl -I https://${FQDN}${BASE_PATH}/

# ICE config endpoint (replace UUID with a real one from an active session)
curl -s https://${FQDN}${BASE_PATH}/v1/turn-creds?peer_id=00000000-0000-0000-0000-000000000000
# Expect 403 (no active session) — proves the endpoint is wired up.
```

## Features over upstream

This deployment adds three things to the upstream LocalSend web/server:

1. **Sub-path hosting** (`BASE_PATH=/send`) — run alongside other apps on
   the same domain.
2. **Room codes** — peers can share a `?room=<code>` URL to discover each
   other across IP families (fixes dual-stack v4↔v6 isolation). Clickable
   "Room" cell in the header, like the existing PIN cell. URL `?room=`
   param persists across refresh.
3. **Self-hosted STUN/TURN with HMAC credentials** — coturn integrated
   into the compose stack. The signaling server mints short-lived TURN
   credentials (HMAC-SHA1) bound to active WebSocket sessions, so the
   endpoint can't be drive-by scraped.

## Alternative coturn deployment

If you'd rather run coturn directly on the host (managed by systemd) and
add TURNS / TLS support, see [docs/coturn-apt-deployment.md](docs/coturn-apt-deployment.md).
The web/signaling sides don't care which way coturn is deployed.

## Updating a submodule

```bash
cd localsend-server         # or localsend-web
# ...make changes...
git add . && git commit -m "..." && git push
cd ..
# Parent now sees a "dirty" submodule pointer — bump it:
git add localsend-server
git commit -m "bump localsend-server: <what changed>"
git push
```

To pull the latest from a submodule's tracking branch without committing
inside it:

```bash
git submodule update --remote localsend-server
```

## Syncing with upstream

Each submodule's `main` tracks its upstream (`localsend/localsend` for the
server, `localsend/web` for the web client); the custom work lives on feature
branches stacked on `main`:

```
server  feat/room-codes  = main + room-codes/TURN/Dockerfile commits
web     feat/basepath     = main + sub-path/signaling commits
web     feat/room-codes   = feat/basepath + room-codes commits   (stacked)
```

`scripts/sync-upstream.sh` fast-forwards each `main` to upstream and rebases
those feature branches on top (handling the web stack with `git rebase --onto`
so shared commits aren't duplicated). It's a dry-run by default — it does the
fetch + ff-merge + rebase locally and prints the force-push commands:

```bash
scripts/sync-upstream.sh           # sync + rebase locally, print pending pushes
scripts/sync-upstream.sh --push    # ...and push (main normal, branches --force-with-lease)
```

It skips any submodule with a dirty tree or a `main` that has diverged from
upstream (those need a manual look), and aborts cleanly on a rebase conflict.
After pushing rebased branches, bump the parent's pinned submodule SHAs:

```bash
git add localsend-server localsend-web
git commit -m "bump submodules after upstream sync"
```

## Repos

- This orchestration repo: <https://github.com/tracyhatemice/localsend>
- Signaling server fork: <https://github.com/tracyhatemice/localsend-server>
- Web client fork: <https://github.com/tracyhatemice/localsend-web>
- Upstream: <https://github.com/localsend/localsend>
