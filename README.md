<p align="center">
  <img src="docs/assets/nilchela-logo.svg" width="360" alt="A cartoon claw gripping a hammer between two angle brackets.">
</p>

<h1 align="center">nilchela</h1>

<p align="center"><strong>"the empty claw, equipped."</strong></p>

---

A thin, development-enabled image for [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) agents — the official base plus a clean pattern for provisioning language toolchains *at runtime* instead of baking them in, built on `build-essential` and the [`mise`](https://mise.jdx.dev) version manager.

Built with ❤️ by [rawlink](https://github.com/rawlink) on the official [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) base image (MIT OR Apache-2.0). nilchela is an independent community project and is not affiliated with or endorsed by ZeroClaw Labs.

---

## Why this exists

The official ZeroClaw image (`ghcr.io/zeroclaw-labs/zeroclaw`) is deliberately minimal — a lean agent host with `bash`, `git`, `curl`, and nothing else. That's the right call for its job (small attack surface).

But an agent that needs to *build* things — run `cargo`, `go`, `node`, `python` — has no toolchain. Baking those in creates a ~3 GB image that rebuilds on every version bump and pulls slowly.

**nilchela decouples the two.** It layers `mise` + OS build tools on the base, then installs pinned toolchains into a mounted volume at container start. The result:

| | Baked-in toolchains | nilchela |
|---|---|---|
| Image size | ~3 GB | ~700 MB |
| Version bump | full rebuild + re-pull | edit `mise.toml` + roll |
| Non-root posture | often broken | preserved (`USER 65534`) |
| Toolchain set | fixed at build | configurable per-deploy |

Because the toolchains live in a volume rather than the image, rebuilding the image leaves them untouched — and wiping the volume to reclaim space does not require a rebuild.

---

## How it works

1. **Build a thin image** — OS tooling + the `mise` CLI. No toolchains.
2. **Pin tools in `mise.toml`** — exact versions for `go`, `node`, `python`, `rust`, `uv`, `gh`, and runtime env (build-cache locations). See [`mise.toml.example`](mise.toml.example).
3. **Install at start** — an initContainer runs `mise install` into a mounted `/tools` volume (root-owned). `mise` is address-and-skip: a warm volume starts near-instantly, offline-quiet.
4. **Run non-root** — the agent container mounts `/tools` read-only and invokes tools via shims on `PATH`.
5. **Enter through `mise exec`** — the image overrides the base `ENTRYPOINT`, so the daemon starts as `mise exec -- /usr/local/bin/zeroclaw daemon` and inherits the full mise environment: `PATH` assembled from the shims and the active tool directories, plus every `[env]` variable from `mise.toml`. There is deliberately **no baked `PATH`** and no wrapper script — `mise exec` is the primitive. If you replace the entrypoint, you own this: source `mise env` yourself, or the child process sees no toolchain.

---

## What's included

**OS-level (apt):** `build-essential`, `pkg-config`, `ca-certificates`, `curl`, `jq`, `git-lfs`, `openssh-client`, `unzip`, `xz-utils` — layered on the base's `bash`/`git`/`curl`.

**Runtime toolchains (via `mise`, configurable):** nothing is baked in. You pin the set you want in your `mise.toml` (Go, Node, Python, Rust with `rustfmt` + `clippy`, `uv`, the GitHub CLI, …) — add/remove tools there without touching the image.

---

## Install

### Kubernetes (Helm)

This repo ships a reference chart at [`charts/nilchela`](charts/nilchela) — a thin wrapper around the [bjw-s `app-template`](https://bjw-s-labs.github.io/helm-charts/docs/app-template/) chart. It renders the StatefulSet, the three volumes, the `mise.toml` ConfigMap, and the ownership model described above.

Run the following from the repository root — the trailing `.` is the build context.

```bash
git clone https://github.com/infiniteprimates/nilchela.git
cd nilchela

helm dependency build charts/nilchela
helm install nilchela charts/nilchela --namespace nilchela --create-namespace
```

The chart installs **no toolchains** — nothing is pinned until you say so. Pin them, then roll:

```bash
helm upgrade nilchela charts/nilchela \
  --set-file 'app-template.configMaps.config.data.mise\.toml=./mise.toml'
```

Use the release name `nilchela` and you get StatefulSet `nilchela` with PVCs `nilchela-tools`, `nilchela-cache`, and `nilchela-data`. Requires Kubernetes `>= 1.28` and Helm 3.x.

Full values reference, naming rules, and the reasoning behind the no-`fsGroup` ownership model: [`charts/nilchela/README.md`](charts/nilchela/README.md). Your cluster's specifics — namespace, storage classes, resources — stay in your own values file or infra repo; the chart only wants values.

> The chart is not published to an OCI registry yet, so `git clone` is the install path. Until then, pin to a commit or tag if you're wiring it into a GitOps repo.

### Docker

Build it:

```bash
docker build -f Dockerfile -t nilchela:dev .
```

Emulate the pod locally before you put it in a cluster — the pod's ownership model is the part that fails quietly:

```bash
docker volume create zc-tools
docker volume create zc-cache
# ...see docs/docker.md for the full three-volume emulation
```

Full detail — build args, the local pod emulation, the storage model, and how `mise.toml` splits across the image and the ConfigMap: **[docs/docker.md](docs/docker.md)**.

---

## Configuration

`mise.toml` is the single source of truth: `[tools]` pins exact versions, `[env]` carries toolchain runtime variables. Both live in the ConfigMap the chart mounts at `/config/mise.toml`, which keeps the image decoupled from the toolchain set — add a tool there and no image change is needed.

Start from [`mise.toml.example`](mise.toml.example), and read [`docs/docker.md` → Configuration](docs/docker.md#configuration) for why `mise`'s own bootstrap variables live in the Dockerfile instead.

> Bump a tool by editing `mise.toml` and rolling the pod. The image does not rebuild, and only the delta downloads on next start.

---

## Publishing

The image is published to **GitHub Container Registry** (`ghcr.io/infiniteprimates/nilchela`) **on `v*` git tags only**, multi-arch, as `<semver>` / `<major>.<minor>` / `sha-<commit>`. No `latest`. Pull requests build but never push.

GHCR creates the package on first push and defaults it to **private** — set its visibility to public in the package settings, or nobody outside the org can pull it.

Push a `v*` tag to publish; pushing to `main` publishes nothing. Registry details and how to point the workflow at a different registry: [`docs/docker.md` → Publishing](docs/docker.md#publishing).

---

## Testing

QA is done against a locally built image before any deploy: build with `docker build -f Dockerfile -t nilchela:dev .`, then run the local-emulation `docker run` sequence above (config staging, cache ownership, init/tool install, main container). Verify the end-state, not the steps: the running container must land on the unprivileged `65534` uid and resolve its installed tools through the `mise` shims.

---

## License

MIT (see [LICENSE](LICENSE)). This project layers on the [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) base image (MIT OR Apache-2.0) and [mise](https://github.com/jdx/mise) (MIT).

---

## Contributing

PRs welcome. Keep the two design invariants intact:

1. **Thin image** — no toolchains baked in; they install at runtime via `mise`.
2. **Non-root** — always return to `USER 65534` after any root-only install steps.

If you touch the Helm chart, keep its third: **the agent never writes `/tools`**. [`charts/nilchela/tests/chart_contract.py`](charts/nilchela/tests/chart_contract.py) enforces it.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide. The code of conduct is in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and the security policy in [SECURITY.md](SECURITY.md).

The key design decisions (the `[tools]` vs `[env]` split, storage tiers, the no-`fsGroup` ownership model) are explained inline in [`Dockerfile`](Dockerfile), [`docs/docker.md`](docs/docker.md), and the chart's own README.
