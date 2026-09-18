# The Docker image

Everything about building, emulating, and publishing the nilchela image. The
[main README](../README.md) covers what nilchela is and how to run it; this is
the image-side detail.

---

## Build the image

```bash
docker build \
  -f Dockerfile \
  -t nilchela:dev \
  .
```

Override the base or `mise` version via build args:

```bash
docker build \
  -f Dockerfile \
  --build-arg ZEROCLAW_VERSION=0.8.5 \
  --build-arg MISE_VERSION=v2026.9.3 \
  -t nilchela:dev \
  .
```

Prerequisites: Docker with BuildKit (default in Docker 23+ and recent Docker
Desktop), and network access to `ghcr.io` to pull the ZeroClaw base.

---

## Emulate the pod locally

The pod model has three volumes (`/tools`, `/cache`, `/config`) and a non-root
user. Emulating it locally catches the permission model before it reaches a
cluster — which is worth doing, because the ownership split is the part that
fails quietly.

Start from the pinned example and fill in real versions:

```bash
cp mise.toml.example mise.toml   # then replace every <version>
```

Then:

```bash
# Volumes
docker volume create zc-tools
docker volume create zc-cache

# Emulate pod ownership — chown the cache so the non-root agent can write it
docker run --rm -v zc-cache:/cache busybox chown -R 65534:65534 /cache

# Stage mise.toml (substitute for the ConfigMap)
mkdir -p /tmp/zc-pod/config && cp mise.toml /tmp/zc-pod/config/

# "initContainer" — install pinned toolchains into /tools
docker run --rm \
  -e MISE_DATA_DIR=/tools \
  -e MISE_GLOBAL_CONFIG_FILE=/config/mise.toml \
  -e MISE_TRUSTED_CONFIG_PATHS=/config \
  -e MISE_CACHE_DIR=/cache/mise \
  --entrypoint mise \
  -v zc-tools:/tools -v zc-cache:/cache -v /tmp/zc-pod/config:/config \
  nilchela:dev install

# "main container" — verify tools resolve through shims (read-only /tools)
docker run --rm \
  -e MISE_DATA_DIR=/tools \
  -e MISE_GLOBAL_CONFIG_FILE=/config/mise.toml \
  -e MISE_TRUSTED_CONFIG_PATHS=/config \
  -e PATH="/tools/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  --entrypoint /bin/bash \
  -v zc-tools:/tools:ro -v zc-cache:/cache -v /tmp/zc-pod/config:/config:ro \
  nilchela:dev -lc 'which go cargo node python uv gh && go version && cargo --version'
```

---

## Deployment shape

This is the pod model the image is built for, and what the
[Helm chart](../charts/nilchela/README.md) encodes in values:

1. **An initContainer** runs `mise install` as **root** to populate a `/tools`
   volume from your pinned `mise.toml`.
2. **A second initContainer** `chown`s the volumes to `65534:65534` — the
   ownership the non-root agent needs, and only that. It is not recursive, on
   purpose: a `chown -R` over a warm cache tree is minutes of pod start-up.
3. **The agent container** runs non-root (`65534`), mounts `/tools`
   **read-only**, and gets its toolchain env from shims plus `mise.toml`'s
   `[env]`.

**The deployment deliberately uses no `fsGroup`** — split ownership
(`/tools` → root, `/cache` and `/zeroclaw-data` → `65534`) is done per-volume.
An fsGroup would also grant the agent's group write access to `/tools`, and the
next `mise install` runs as root: that would let the agent overwrite the
toolchains it is about to execute.

> **Requirement:** provision a `zeroclaw-tools` (≈10 GB) and a bounded
> `zeroclaw-cache` PVC, plus storage for `/zeroclaw-data`, and render your
> `mise.toml` into a ConfigMap mounted at `/config`.

---

## Configuration

### `mise.toml` — the single source of truth

All tool versions and runtime env live in a `mise.toml` (rendered into a
ConfigMap at deploy time; use [`mise.toml.example`](../mise.toml.example) as
your starting point). Key sections:

- **`[tools]`** — exact-pinned tool versions. Bump one, and only the delta
  downloads on next start.
- **`[env]`** — toolchain runtime vars (build-cache locations). Kept here —
  **not** in the Dockerfile — so the image stays decoupled from the toolchain
  set.

> **Why this split?** `mise` reads its own bootstrap env (`MISE_DATA_DIR`,
> `MISE_GLOBAL_CONFIG_FILE`, etc.) at process start, before it can read
> `mise.toml` — so those live in the Dockerfile as `ENV`. Toolchain runtime env
> (`CARGO_HOME`, `GOMODCACHE`, …) is surfaced via `mise env`/shims and lives in
> `[env]`. The cache-redirect entries are deliberate policy (keep caches off
> `/zeroclaw-data`), not boilerplate — `mise` can't infer them.

### Generating the environment dynamically

Rather than hand-enumerating env vars, `mise` can emit the full environment it
knows (PATH + `[env]` + tool/plugin-set vars) in one shot:

```bash
eval "$(mise env -s bash)"       # sourceable shell form
mise env --dotenv > .env         # dotenv form
mise env --json                  # json form
```

In the nilchela container this is not required — shims already surface `[env]`
to child processes, and `PATH` is set in the image — but it is the lever if you
want to source everything dynamically instead of relying on the baked `PATH`.

### Storage model

| Path | Purpose | Ownership | Lifecycle |
|---|---|---|---|
| `/tools` | installed toolchains | root (RO to agent) | durable, shared |
| `/cache` | build caches (cargo/go/npm/uv) | 65534 | disposable |
| `/config` | `mise.toml` (ConfigMap) | — | GitOps-tracked |
| `/zeroclaw-data` | repos/workspaces/notes | 65534 | durable |

Build caches are redirected off the durable data volume precisely so it doesn't
balloon with disposable registries.

---

## Publishing

The image is published to **GitHub Container Registry**
(`ghcr.io/infiniteprimates/nilchela`) by
[`.github/workflows/build-publish.yaml`](../.github/workflows/build-publish.yaml),
which runs **on `v*` git tags only**:

- **Tags** — `<semver>` (for example `0.0.3` from git tag `v0.0.3`),
  `<major>.<minor>` (for example `0.0`), and `sha-<commit>`. There is no
  `latest`: a moving tag on an agent image invites silent upgrades.
- **Multi-arch** — native `linux/amd64` + `linux/arm64` via buildx.
- **Auto-created** — GHCR creates the package on first push, and defaults it to
  **private**. Set its visibility to "public" in the GHCR package settings, or
  nobody outside the org can pull it.
- **No registry secret needed** — the workflow's `permissions: packages: write`
  grants what `GITHUB_TOKEN` requires.
- **Pull requests build but do not push**
  ([`pr-build.yaml`](../.github/workflows/pr-build.yaml)), which is the check to
  mark required in branch protection.

To publish: push a `v*` tag. Pushing to `main` does not publish anything.

> For a *different* registry (self-hosted Harbor, Docker Hub, etc.), swap the
> `registry`/`username`/`password` in the login step and add its credentials as
> a secret.
