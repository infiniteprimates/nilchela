# Contributing

Thanks for contributing to **nilchela**. This is a small, focused project, so the bar is simple: keep the two design invariants intact.

## The two invariants

1. **Thin image** — no dev toolchains baked into the image. Toolchains install at runtime via `mise` into a mounted volume. Adding a tool to the *image* (build time) instead of `mise.toml` (runtime) breaks the core value of the project and needs a strong reason.
2. **Non-root** — the image returns to `USER 65534` (the base's posture). Any `root`-only step must be scoped to shell `RUN`/init-container work and followed by a return to non-root.

## Getting started

```bash
git clone https://github.com/infiniteprimates/nilchela.git
cd nilchela
docker build -f Dockerfile -t nilchela:dev .
```

See the README for the full local-emulation and deployment flow.

## Submitting changes

- Open an issue first for anything bigger than a small fix — the maintainers can tell you whether it conflicts with the invariants.
- Keep PRs focused: one change, clearly described.
- Version pins (`MISE_VERSION`, tool versions) are deliberate; explain why you're bumping one.

## Style

- TOML and Dockerfile are the primary formats. Follow the existing comment style — the files are self-documenting by design.
- YAML examples live in the consuming repo, not here; the public repo ships the image recipe only.

The key design decisions (the `[tools]` vs `[env]` split, the storage/ownership model, the no-`fsGroup` rationale) are explained inline in [`Dockerfile`](Dockerfile) and the README.

## Maintainers

This is maintained by the [Infinite Primates](https://github.com/infiniteprimates) org. It layers on [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — give them a look.
