#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mise-install.sh — idempotent toolchain install for the nilchela image.
#
# Runs as the pod's initContainer with RW access to the tools volume; the main
# agent container mounts the same volume read-only.
#
# Idempotency: mise is address-and-skip — `mise install` short-circuits on
# already-installed EXACT versions. A warm tools volume means near-instant,
# offline-quiet startup. Only a version bump in mise.toml triggers a download,
# and only of the new version.
#
# Everything is configured via env (set by the Dockerfile, resolved against
# mounted volumes by the pod manifest):
#   MISE_DATA_DIR            -> /tools   (toolchain install root, RW here, RO main)
#   MISE_GLOBAL_CONFIG_FILE  -> /config/mise.toml (from ConfigMap)
#   MISE_TRUSTED_CONFIG_PATHS-> /config  (trusted non-interactively via env)
#   MISE_CACHE_DIR           -> /cache/mise (shared cache volume)
# -----------------------------------------------------------------------------
set -euo pipefail

# Install pinned tools (skips exact versions already present).
mise install

# Fail loudly if a pinned tool didn't land — surface config drift at start,
# not as a mystery mid-build. The shims resolve via PATH=/tools/shims.
missing=0
for t in go node python uv gh cargo rustc; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "ERROR: pinned tool '$t' not resolvable after install" >&2
        missing=1
    fi
done

exit "$missing"
