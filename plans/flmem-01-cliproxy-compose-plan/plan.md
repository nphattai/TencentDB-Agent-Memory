# flmem-01: cliproxy into fleet-mem compose

Bring `cliproxyapi` into the `fleet-mem` compose project so the whole memory layer
(memory-core + memory-hub + proxy + **cliproxy**) starts with one `docker compose up`,
identically on the MacBook and the Mac mini.

## Refresh vs upfront plan (verified 2026-08-25 at branch HEAD e5f8236/d19232c)

Upfront plan confirmed against HEAD. Anchors verified:

- `deploy/global-images/compose.yaml` present, project `name: fleet-mem`, 3 services
  (memory-core/memory-hub/proxy), external network `tdai-memory-stack` + 2 external volumes.
- `start-all.sh` calls `require_vars ...` then `compose up -d` (project fleet-mem) + `wait_healthy` per container.
- `stop-all.sh` does `compose down` + leftover-container cleanup loop.
- `.env.example` / `_lib.sh` / `lib-config.sh` / README present; `.gitignore` already covers
  `.admin-key`, `.proxy-config/`, `.memory-core-config/`.
- Host native cliproxy: brew service, config `/opt/homebrew/etc/cliproxyapi.conf` (`port: 8317`,
  `auth-dir: "~/.cli-proxy-api"`), auth dir `~/.cli-proxy-api` (OAuth cred json + logs/). Port 8317
  held by PID of native `cliproxyapi`.
- 3 memory containers already RUNNING under label `com.docker.compose.project=fleet-mem`
  (captain already on the compose version). **Must not disrupt them.**

No material divergence from the upfront plan -> no plan-review gate needed.

## Upstream research result (agent-verified, cited)

Actual repo is `router-for-me/CLIProxyAPI` (no hyphens).

- **Official image:** `eceasy/cli-proxy-api:latest` on Docker Hub, multi-arch (`linux/amd64` +
  `linux/arm64`) -> resolves arm64 on Apple Silicon. (from `.github/workflows/docker-image.yml`,
  `docker-compose.yml`).
- **Config path inside container:** `/CLIProxyAPI/config.yaml` (Dockerfile `WORKDIR /CLIProxyAPI`,
  `CMD ["./CLIProxyAPI"]`, app default `config.yaml` in workdir; upstream compose mounts host config there).
- **auth-dir inside container:** `/root/.cli-proxy-api` (container runs as root, config `auth-dir: "~/..."`
  -> `~` = `/root`; upstream compose mounts host auth dir there).
- **Port:** 8317 (config + `EXPOSE 8317` + compose `8317:8317`).

Prefer the upstream image (no local Dockerfile needed).

## Design

Add a `cliproxy` service to `deploy/global-images/compose.yaml` mirroring upstream's two mounts,
parameterized through `.env`:

```yaml
  cliproxy:
    image: ${CLIPROXY_IMAGE:-eceasy/cli-proxy-api:latest}
    container_name: tdai-cliproxy
    restart: unless-stopped
    networks: [tdai-memory-stack]
    ports:
      - "${CLIPROXY_PORT:-8317}:8317"      # match native *:8317 (all interfaces)
    volumes:
      - ${CLIPROXY_CONFIG_FILE:?...}:/CLIProxyAPI/config.yaml:ro   # app only reads config
      - ${CLIPROXY_AUTH_DIR:-${HOME}/.cli-proxy-api}:/root/.cli-proxy-api  # rw: OAuth token refresh writes back
```

Parameterization rationale (brief: no machine-specific hardcode in compose):
- `CLIPROXY_CONFIG_FILE`: **required** (`:?`) - `/opt/homebrew/etc/...` exists only on the MacBook;
  no portable default. Set in `.env.example` to the MacBook path with a mini note.
- `CLIPROXY_AUTH_DIR`: **defaulted** in compose to `${HOME}/.cli-proxy-api` (portable, upstream default,
  same precedent as existing `MEMORY_HUB_REPOS_MOUNT:-${HOME}/Work/repo`). Left commented in `.env.example`.
- config mount `:ro` (read-only, app never writes config = brief "READ"). auth-dir **rw**: cliproxy
  refreshes OAuth tokens + writes `logs/` into it; `:ro` would break token refresh. Correct > literal.
- Attach to `tdai-memory-stack` for cohesion (proxy could route upstream to `http://cliproxy:8317`).
- No healthcheck in image -> `wait_healthy` treats running as ready.

## File changes

1. **compose.yaml** - add `cliproxy` service (above).
2. **.env.example** - add cliproxy block: `CLIPROXY_IMAGE`, `CLIPROXY_PORT=8317`,
   `CLIPROXY_CONFIG_FILE=/opt/homebrew/etc/cliproxyapi.conf` (MacBook default + mini note),
   commented `# CLIPROXY_AUTH_DIR=${HOME}/.cli-proxy-api`.
3. **start-all.sh** - add `CLIPROXY_IMAGE CLIPROXY_PORT CLIPROXY_CONFIG_FILE` to `require_vars`;
   pre-flight check config file + auth dir exist on host (die with guidance if missing);
   `wait_healthy tdai-cliproxy` after up.
4. **stop-all.sh** - add `tdai-cliproxy` to leftover-container cleanup loop (compose down handles it via the file).
5. **_lib.sh `print_endpoints`** - add CLIProxy line (`${CLIPROXY_PORT:-8317}`).
6. **README.md** - component table row; mini bring-up section (git pull + copy 2 secrets + up -d);
   Homebrew-service migration note (`brew services stop cliproxyapi` one-time, manual captain step).

## Security

- No secret enters the repo: config + auth-dir are absolute HOST paths mounted via `.env`; nothing copied in.
- `.env.example` ships placeholders/paths only. No `cliproxyapi.conf.example` needed (captain copies the real
  file from MacBook to mini per bring-up).
- Verify `git status` clean of secrets before PR. `.gitignore` already covers `.env` (real). No new repo
  path holds secrets, so no `.gitignore` change strictly required - confirm and add only if a new tracked
  secret path appears.

## Local verify (non-disruptive)

3 memory containers already run under `fleet-mem`; must not disrupt. Plan:
1. `brew services stop cliproxyapi` (free 8317) - manual host step, NOT scripted.
2. `docker compose -p fleet-mem -f compose.yaml --project-directory . --env-file .env up -d cliproxy`
   (adopts existing external network; only creates the 4th service, leaves the 3 running untouched).
3. `docker ps` shows 4 under fleet-mem; `curl -H "Authorization: Bearer <api-key>" http://127.0.0.1:8317/v1/models` answers.
4. Clean up my verify container (`stop`+`rm cliproxy`), `brew services start cliproxyapi` to restore host.

## Acceptance -> coverage

1. compose cliproxy service (image/port/mounts via .env) -> change #1.
2. one-command up-all + README mini + migration note -> changes #3,#4,#6.
3. .env.example added, no secret, .gitignore verified -> change #2 + security.
4. local verify cliproxy answers on 8317 -> verify section.
5. direct-PR to `fleet-patches`.
