# syntax=docker/dockerfile:1.7-labs

# =============================================================================
# nilchela — "the empty claw, equipped"
#
# A thin, opinionated dev image for [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw)
# agents. It layers OS-level tooling + the `mise` version manager on top of the
# official ZeroClaw Debian base, then installs dev toolchains at *runtime* (not
# build time).
#
# This image carries three things:
#   1. OS-level tooling (apt) layered on the base's bash/curl/git/vim-tiny.
#   2. The `mise` CLI — the version manager that installs dev toolchains.
#   3. An ENTRYPOINT that runs the base daemon under `mise exec`, so the process
#      inherits the toolchain env + [env] vars (see the ENTRYPOINT note below).
#
# Dev toolchains (go/node/python/rust/uv/gh) are installed at container start by
# an initContainer running `mise install` directly, reading pins from a
# ConfigMap-mounted mise.toml. Version bumps = edit mise.toml + roll; the image
# does NOT rebuild.
#
# Design principles:
#   * THIN IMAGE — no toolchains baked in (~300 MB vs ~3 GB). Fast pull.
#   * NON-ROOT — returns to USER 65534 (the base's posture) after install.
#   * DECOUPLED — toolchain env vars live in mise.toml's [env], NOT here (see
#     the `# MISE SELF-CONFIG` note below).
# =============================================================================

# Abstract the base image version away from this image's own version.
ARG ZEROCLAW_VERSION=0.8.5
FROM ghcr.io/zeroclaw-labs/zeroclaw:v${ZEROCLAW_VERSION}-debian

# mise CLI version — pin to the current release (bump deliberately).
ARG MISE_VERSION=v2026.9.3

USER root

# ---- OS-level tooling (bash/curl/git/vim-tiny already in base) -------------
# build-essential + pkg-config = native-compile baseline. Deliberately NOT
# installing libssl-dev (OpenSSL headers) — portability-lean default.
# unzip + xz-utils = needed by mise to extract toolchain archives at install.
# jq + git-lfs + openssh-client = general dev/ops conveniences.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        pkg-config \
        jq \
        git-lfs \
        openssh-client \
        unzip \
        xz-utils \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# ---- mise CLI only (toolchains are installed at runtime, not here) --------
RUN curl -fsSL https://mise.run -o /tmp/install-mise.sh \
    && MISE_INSTALL_PATH=/usr/local/bin/mise MISE_VERSION="${MISE_VERSION}" sh /tmp/install-mise.sh \
    && rm /tmp/install-mise.sh

# ---- MISE SELF-CONFIG ------------------------------------------------------
# ONLY mise's own bootstrap env goes here. These are read by mise at process
# start (before it can read mise.toml), so they CANNOT live in [env].
#
#   MISE_DATA_DIR           -> /tools   (toolchain install root = tools volume)
#   MISE_GLOBAL_CONFIG_FILE -> /config/mise.toml (ConfigMap-mounted pins)
#   MISE_TRUSTED_CONFIG_PATHS-> /config (trust that config non-interactively)
#   MISE_RUSTUP_HOME        -> /tools/rustup  (rust toolchains live OUTSIDE
#                               mise's installs dir; rustup manages them)
#   MISE_CACHE_DIR          -> /cache/mise (mise's own download cache)
#
# Toolchain RUNTIME env (CARGO_HOME, GOMODCACHE, GOCACHE, NPM_CONFIG_CACHE,
# UV_CACHE_DIR, ...) deliberately does NOT live here. It belongs in mise.toml's
# [env] section and is surfaced via `mise env` — which the entrypoint sources,
# and shims apply to child processes. That keeps this Dockerfile decoupled from
# the specific toolchain set — add a tool in mise.toml, no image change needed.
#
# PATH is also omitted here on purpose: the entrypoint builds it via `mise env`
# (shims + active tool dirs), a single source of truth instead of a hand-
# maintained list that would drift as tools change.
ENV MISE_DATA_DIR=/tools \
    MISE_GLOBAL_CONFIG_FILE=/config/mise.toml \
    MISE_TRUSTED_CONFIG_PATHS=/config \
    MISE_RUSTUP_HOME=/tools/rustup \
    MISE_CACHE_DIR=/cache/mise

# ---- Entrypoint: run the base daemon under mise exec ----------------------
# The base image runs ENTRYPOINT ["zeroclaw"] + CMD ["daemon"]. We override
# ENTRYPOINT to `mise exec`, which applies the full mise environment (PATH via
# shims + the mise.toml [env] vars) to the child process and runs it. CMD
# ["daemon"] is inherited from the base and appended after `--`, yielding:
#   mise exec -- /usr/local/bin/zeroclaw daemon
# No wrapper script is needed — `mise exec` is the native primitive for this.
ENTRYPOINT ["mise", "exec", "--", "/usr/local/bin/zeroclaw"]
CMD daemon

# ---- Back to the image's non-root posture ----------------------------------
USER 65534:65534
WORKDIR /zeroclaw-data
