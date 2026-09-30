#!/usr/bin/env python3
"""Contract test for the nilchela chart — asserts the invariants the chart
exists to encode, against a live `helm template` render.

Why this exists: the chart delegates all rendering to the bjw-s `common`
library, so what is *ours* is the translation (`templates/_translate.tpl`) and
the pod model it emits — root installer, non-root agent, read-only /tools, split
ownership, no fsGroup — plus the gateway's exposure posture (ClusterIP Service
on the gateway port, bound off loopback, readiness and liveness probes on the
daemon's health route). Asserting the translation
against *real output* rather than against our own values.yaml is the point: a
faithful translation is a claim about what the library renders, and the only
place that claim can be checked is here. This runs on every PR and on every
`common` bump.

Deliberately dependency-light (PyYAML plus the standard library): it renders
nothing, it inspects what Helm produced. `--check-package` is the one exception
-- it shells out to `helm package` into a temporary directory to inspect the
artifact a recipient would actually receive. Everything else is read-only.

Usage:
    helm template nilchela charts/nilchela > /tmp/rendered.yaml
    python3 charts/nilchela/tests/chart_contract.py /tmp/rendered.yaml \
        --chart-dir charts/nilchela --release-name nilchela

The licence checks run unconditionally, before the render checks, and only need
the two trees -- so they hold even if the render is wrong. Add --check-package
(and a `helm dependency build` first) to assert the packaged artifact too.

Add --toolenv-render to also assert the `mise.env` -> `[env]` mapping against a
second render made with toolchain env set (see check_toolenv), and
--probes-render for a third with a probe enabled and the Service disabled
(see check_probes).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tarfile
import tempfile
import tomllib

import yaml

AGENT_UID = 65534
TOOLS_PATH = "/tools"
CONFIG_PATH = "/config"
CACHE_PATH = "/cache"
DATA_PATH = "/zeroclaw-data"
GATEWAY_PORT = 42617

# The three files Apache-2.0 §4 obliges us to hand to anyone who receives the
# packaged chart. They exist twice on purpose: once at the repo root (where a
# reader looks for them) and once inside charts/nilchela (because `helm package`
# walks only the chart directory -- there is no include-from-outside, and a
# published tarball is a redistribution). The duplication is load-bearing, so it
# is asserted rather than trusted.
#
# The assertion is relational, not pinned: the chart copies are compared against
# the root originals, and the packaged members against the root originals too.
# No hash of the licence text is written down here. Editing a licence is a
# deliberate act, and rewriting both copies to match is what a deliberate edit
# looks like -- not a failure for a test to invent. What this does catch is one
# copy moving without the other, a symlink standing in for a copy, and an
# artifact that does not carry what the tree carries.
LICENSE_FILES = ("LICENSE-MIT", "LICENSE-APACHE", "NOTICE")


class Checker:
    """Collects results so one failure does not hide the rest."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passes: list[str] = []

    def check(self, label: str, condition: bool, detail: str = "") -> None:
        if condition:
            self.passes.append(label)
        else:
            self.failures.append(f"{label}{': ' + detail if detail else ''}")

    def report(self) -> int:
        for label in self.passes:
            print(f"  ok   {label}")
        for label in self.failures:
            print(f"  FAIL {label}")
        print(f"\n{len(self.passes)} passed, {len(self.failures)} failed")
        return 1 if self.failures else 0


def load_manifests(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        return [doc for doc in yaml.safe_load_all(handle) if doc]


def by_kind(manifests: list[dict], kind: str) -> list[dict]:
    return [doc for doc in manifests if doc.get("kind") == kind]


def container(pod_spec: dict, name: str, init: bool = False) -> dict | None:
    key = "initContainers" if init else "containers"
    for item in pod_spec.get(key) or []:
        if item.get("name") == name:
            return item
    return None


def mount_for(container_spec: dict, path: str) -> dict | None:
    for item in container_spec.get("volumeMounts") or []:
        if item.get("mountPath") == path:
            return item
    return None


def volume_for(pod_spec: dict, volume_name: str) -> dict | None:
    for item in pod_spec.get("volumes") or []:
        if item.get("name") == volume_name:
            return item
    return None


def spec_of(manifest: dict) -> dict:
    return manifest.get("spec") or {}


def read_default_tag(chart_dir: str) -> tuple[str | None, str | None]:
    """Return (Chart.yaml appVersion, values.yaml default image tag)."""
    with open(f"{chart_dir}/Chart.yaml", encoding="utf-8") as handle:
        app_version = (yaml.safe_load(handle) or {}).get("appVersion")
    with open(f"{chart_dir}/values.yaml", encoding="utf-8") as handle:
        values = yaml.safe_load(handle) or {}
    tag = (values.get("image") or {}).get("tag")
    return (
        str(app_version) if app_version is not None else None,
        str(tag) if tag is not None else None,
    )


def sha256_of(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def check_licenses(repo_root: str, chart_dir: str, checker: Checker) -> None:
    """The chart-local licence copies are real files, byte-identical to the root
    originals.

    Two distinct failure modes, and identity alone does not catch both:

    * a *symlink* instead of a copy -- correct on Linux and macOS, because
      `helm package` dereferences it, but a checkout with `core.symlinks=false`
      (Windows without Developer Mode, or a GitHub source ZIP) materialises it as
      a text file containing the target path, and the packaged chart then ships
      a ~20-byte stub as the licence text, silently. The bytes look right in the
      repo and wrong in the artifact, so identity alone does not catch it: the
      type has to be asserted too.
    * *drift* -- one copy edited, the other not.

    A rewrite of *both* copies is not a failure: it is what a deliberate licence
    change looks like, and the diff is where that gets reviewed.
    """
    for name in LICENSE_FILES:
        root = os.path.join(repo_root, name)
        local = os.path.join(chart_dir, name)
        actual = os.path.normpath(root)

        if not os.path.isfile(root) or os.path.islink(root):
            checker.check(f"{name} is a regular file at the repo root", False, actual)
            continue
        chart_ok = os.path.isfile(local) and not os.path.islink(local)
        checker.check(
            f"{name} is a regular file inside the chart (not a symlink)",
            chart_ok,
            "missing" if not os.path.exists(local) else "a symlink",
        )
        if not chart_ok:
            continue

        digest = sha256_of(root)
        local_digest = sha256_of(local)
        checker.check(
            f"{name}: the chart copy is byte-identical to the root copy",
            local_digest == digest,
            f"root={digest[:16]} chart={local_digest[:16]}",
        )


def check_packaged_licenses(repo_root: str, chart_dir: str, checker: Checker) -> None:
    """The *packaged artifact* carries the three files, with the bytes the repo
    carries.

    This is the only layer that sees what a recipient actually receives. It is
    what catches `.helmignore` growing a `LICENSE*` pattern, a dependency that
    was never built, or -- when the copies are materialised by a build step
    rather than committed -- the build step silently not running. The packaged
    bytes are compared against the repo root's, which is the copy the tree layer
    already ties the chart copies to; no hash is pinned here, so rewriting the
    licence everywhere stays a deliberate act rather than a test failure.

    Requires `helm` on PATH and the chart dependencies resolved in charts/:
    `helm package` refuses to package a chart whose declared dependencies are
    absent, so this runs after `helm dependency build`. Packaging is offline once
    the dependency is vendored, and writes to a temporary directory.
    """
    with tempfile.TemporaryDirectory() as destination:
        result = subprocess.run(
            ["helm", "package", chart_dir, "--destination", destination],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            checker.check("helm package succeeds", False, result.stderr.strip())
            return
        archives = [name for name in os.listdir(destination) if name.endswith(".tgz")]
        checker.check(
            "helm package produces exactly one archive", len(archives) == 1, str(archives)
        )
        if len(archives) != 1:
            return

        chart_name = os.path.basename(os.path.normpath(chart_dir))
        with tarfile.open(os.path.join(destination, archives[0])) as package:
            members = {member.name: member for member in package.getmembers()}
            for name in LICENSE_FILES:
                member = members.get(f"{chart_name}/{name}")
                checker.check(f"the packaged chart carries {name}", member is not None)
                if member is None:
                    continue
                checker.check(f"{name} is a regular file in the packaged chart", member.isfile())
                if not member.isfile():
                    continue
                payload = package.extractfile(member)
                digest = hashlib.sha256(payload.read() if payload else b"").hexdigest()
                root_path = os.path.join(repo_root, name)
                if not os.path.isfile(root_path):
                    checker.check(
                        f"{name}: a root copy exists to compare the packaged bytes against",
                        False,
                        root_path,
                    )
                    continue
                root_digest = sha256_of(root_path)
                checker.check(
                    f"{name}: the packaged bytes match the repo root",
                    digest == root_digest,
                    f"root={root_digest[:16]} packaged={digest[:16]}",
                )


def run_checks(manifests: list[dict], chart_dir: str, checker: Checker) -> None:
    statefulsets = by_kind(manifests, "StatefulSet")
    checker.check(
        "exactly one StatefulSet is rendered",
        len(statefulsets) == 1,
        f"found {len(statefulsets)}",
    )
    if len(statefulsets) != 1:
        return

    pod_spec = spec_of(statefulsets[0]).get("template", {}).get("spec") or {}

    # -- the StatefulSet has a serviceName. app-template defaults it to the
    # chart fullname; a StatefulSet without it is rejected by the API server,
    # so this is populated whether or not any Service is rendered.
    checker.check(
        "StatefulSet sets spec.serviceName",
        bool(spec_of(statefulsets[0]).get("serviceName")),
    )

    # -- exactly one Service, ClusterIP, on the gateway port.
    #
    # `zeroclaw daemon` supervises an HTTP gateway, so there IS an inbound
    # surface — the chart fronts it. What is asserted is that it is exposed
    # inside the cluster only, and on the gateway's port. The type is a
    # security invariant, not a preference: anything but ClusterIP publishes an
    # unauthenticated /health (pairing state + runtime snapshot) beyond the
    # cluster boundary.
    services = by_kind(manifests, "Service")
    checker.check(
        "exactly one Service is rendered",
        len(services) == 1,
        f"found {len(services)}",
    )
    if len(services) == 1:
        service_spec = spec_of(services[0])
        checker.check(
            "the Service is ClusterIP (the gateway is not published off-cluster)",
            service_spec.get("type") in (None, "ClusterIP"),
            f"type={service_spec.get('type')!r}",
        )
        service_ports = service_spec.get("ports") or []
        checker.check(
            f"the Service exposes the gateway port {GATEWAY_PORT}",
            any(str(port.get("port")) == str(GATEWAY_PORT) for port in service_ports),
            f"ports={[port.get('port') for port in service_ports]}",
        )

    # -- no fsGroup anywhere on the pod (see values.yaml for why).
    pod_security = pod_spec.get("securityContext") or {}
    checker.check(
        "pod does not set fsGroup (split ownership is per-volume)",
        "fsGroup" not in pod_security,
    )

    main = container(pod_spec, "main")
    checker.check("main container exists", main is not None)
    if main:
        # -- the agent runs as the image's non-root user, read-only on /tools.
        security = main.get("securityContext") or {}
        checker.check(
            f"main container runs as uid {AGENT_UID}",
            security.get("runAsUser") == AGENT_UID,
            f"runAsUser={security.get('runAsUser')!r}",
        )
        checker.check("main container sets runAsNonRoot", security.get("runAsNonRoot") is True)

        tools_mount = mount_for(main, TOOLS_PATH)
        checker.check(
            f"main container mounts {TOOLS_PATH} read-only",
            tools_mount is not None and tools_mount.get("readOnly") is True,
        )

        # -- no command/args: the image's `mise exec -- ...` entrypoint must
        # survive, or the toolchain environment never reaches the daemon.
        checker.check(
            "main container does not override the image entrypoint/CMD",
            not main.get("command") and not main.get("args"),
        )

        # -- the gateway must listen on an interface the Service can dial.
        # The PVC at /zeroclaw-data shadows the image's baked config.toml, which
        # drops the gateway to its schema default (host 127.0.0.1); without
        # these overrides the Service above fronts a port nothing outside the
        # pod can reach. The two checks move together by design.
        env_map = {
            item.get("name"): item.get("value")
            for item in (main.get("env") or [])
            if isinstance(item, dict)
        }
        bind_host = env_map.get("ZEROCLAW_gateway__host")
        checker.check(
            "main container binds the gateway off loopback",
            bind_host not in (None, "", "127.0.0.1", "localhost"),
            f"ZEROCLAW_gateway__host={bind_host!r}",
        )
        allow_public = env_map.get("ZEROCLAW_gateway__allow_public_bind")
        checker.check(
            "main container opts into a non-loopback bind explicitly",
            str(allow_public).lower() == "true",
            f"ZEROCLAW_gateway__allow_public_bind={allow_public!r}",
        )

        # -- the default probe set. Readiness and liveness ship on, because a
        # daemon that cannot serve /health is the one failure a restart fixes;
        # both target the health route, and neither is a startup probe (the slow
        # part of a cold install is an init container). The budget is asserted in
        # values_surface_test.yaml; what matters here is the shape.
        readiness_probe = main.get("readinessProbe") or {}
        liveness_probe = main.get("livenessProbe") or {}
        checker.check(
            "main container carries readiness and liveness probes by default",
            bool(readiness_probe) and bool(liveness_probe),
            f"readiness={readiness_probe!r} liveness={liveness_probe!r}",
        )
        checker.check(
            "both default probes target the gateway's /health",
            (readiness_probe.get("httpGet") or {}).get("path") == "/health"
            and (liveness_probe.get("httpGet") or {}).get("path") == "/health",
            f"{readiness_probe.get('httpGet')!r} / {liveness_probe.get('httpGet')!r}",
        )
        checker.check(
            "no startup probe by default (the cold install is an init container)",
            not main.get("startupProbe"),
        )
        checker.check(
            "liveness is given a budget loose enough for a busy build host",
            int((liveness_probe.get("failureThreshold") or 0))
            * int((liveness_probe.get("periodSeconds") or 0))
            >= 120,
            f"failureThreshold={liveness_probe.get('failureThreshold')!r} "
            f"periodSeconds={liveness_probe.get('periodSeconds')!r}",
        )

    # -- the installer: root, on the RW side of /tools, actually running mise.
    installer = container(pod_spec, "install-tools", init=True)
    checker.check("install-tools initContainer exists", installer is not None)
    if installer:
        checker.check(
            "install-tools runs as root (it writes the root-owned /tools)",
            (installer.get("securityContext") or {}).get("runAsUser") == 0,
        )
        checker.check(
            "install-tools runs `mise install`",
            (installer.get("command") or [None])[0] == "mise"
            and "install" in (installer.get("args") or []),
        )
        # This is the load-bearing translation assumption: the library resolves
        # `advancedMounts.main.<initContainer-key>`, so an initContainer can be
        # given a different mount mode on the same volume as the main container.
        # If that ever stops being true, /tools ends up root-writable by the
        # agent (or empty for the installer) and the product silently has no
        # toolchains.
        tools_mount = mount_for(installer, TOOLS_PATH)
        checker.check(
            f"install-tools gets a writable {TOOLS_PATH} mount (advancedMounts "
            "resolves initContainer keys)",
            tools_mount is not None and not tools_mount.get("readOnly"),
            "no mount at all" if tools_mount is None else "mounted read-only",
        )

    # -- and the two must address the SAME volume. If they drift apart — a
    # mis-keyed advancedMounts entry, or the persistence item split in two —
    # the installer writes into a volume the agent never reads. The pod renders
    # perfectly and the product has no toolchains. Presence checks cannot catch
    # that; identity can.
    if main is not None and installer is not None:
        main_tools = mount_for(main, TOOLS_PATH)
        installer_tools = mount_for(installer, TOOLS_PATH)
        main_name = (main_tools or {}).get("name")
        installer_name = (installer_tools or {}).get("name")
        checker.check(
            f"main and install-tools mount the same volume at {TOOLS_PATH}",
            main_name is not None and main_name == installer_name,
            f"main={main_name!r} install-tools={installer_name!r}",
        )

    # -- and in that order. app-template orders initContainers by dependency;
    # if the `dependsOn` edge is lost, the installer can write the root-owned
    # tree before `fix-ownership` settles ownership on the volumes.
    init_names = [item.get("name") for item in pod_spec.get("initContainers") or []]
    checker.check(
        "fix-ownership runs before install-tools",
        "fix-ownership" in init_names
        and "install-tools" in init_names
        and init_names.index("fix-ownership") < init_names.index("install-tools"),
        f"order={init_names}",
    )

    ownership = container(pod_spec, "fix-ownership", init=True)
    checker.check("fix-ownership initContainer exists", ownership is not None)
    if ownership:
        checker.check(
            "fix-ownership runs as root",
            (ownership.get("securityContext") or {}).get("runAsUser") == 0,
        )
        checker.check(
            "fix-ownership chowns /cache and /zeroclaw-data to the agent uid",
            (ownership.get("command") or [None])[0] == "chown"
            and f"{AGENT_UID}:{AGENT_UID}" in (ownership.get("args") or [])
            and CACHE_PATH in (ownership.get("args") or [])
            and DATA_PATH in (ownership.get("args") or []),
        )

    # -- /config is a ConfigMap holding the mise.toml key, mounted read-only.
    config_mount = None
    for candidate in (main or {}).get("volumeMounts") or []:
        if candidate.get("mountPath") == CONFIG_PATH:
            config_mount = candidate
    checker.check(
        f"{CONFIG_PATH} is mounted read-only",
        config_mount is not None and config_mount.get("readOnly") is True,
    )
    if config_mount:
        volume = volume_for(pod_spec, config_mount.get("name", ""))
        checker.check(
            f"{CONFIG_PATH} is backed by a ConfigMap volume",
            bool((volume or {}).get("configMap")),
        )
        configmaps = by_kind(manifests, "ConfigMap")
        checker.check(
            "a ConfigMap provides the mise.toml key",
            any("mise.toml" in (doc.get("data") or {}) for doc in configmaps),
        )
        mise_toml = mise_toml_from(configmaps)
        # The chart pins no toolchain and no toolchain env — what is installed, and
        # the variables that toolchain needs, are deployment policy. Both tables
        # exist only when the deployment supplies them. Parsed, not string-matched:
        # a malformed table must fail here rather than at pod start.
        parsed = tomllib.loads(mise_toml)
        checker.check(
            "the rendered mise.toml parses and pins no toolchain or toolchain env",
            "tools" in parsed and parsed.get("env") is None,
            f"mise.toml={mise_toml!r}",
        )

    # -- the three claims exist and survive `helm uninstall`.
    pvcs = by_kind(manifests, "PersistentVolumeClaim")
    for suffix, size in (("-tools", "10Gi"), ("-cache", "5Gi"), ("-data", "10Gi")):
        match = [doc for doc in pvcs if doc["metadata"]["name"].endswith(suffix)]
        checker.check(f"PVC {suffix} is rendered", len(match) == 1)
        if len(match) == 1:
            annotations = match[0]["metadata"].get("annotations") or {}
            checker.check(
                f"PVC {suffix} is retained across `helm uninstall`",
                annotations.get("helm.sh/resource-policy") == "keep",
            )
            requests = (match[0]["spec"].get("resources") or {}).get("requests") or {}
            checker.check(
                f"PVC {suffix} requests {size}",
                requests.get("storage") == size,
                f"got {requests.get('storage')!r}",
            )

    # -- drift guard: appVersion is the image this chart deploys by default. An
    # empty values `image.tag` means "inherit it", so what must not drift is the
    # *rendered* tag, not the raw values entry — comparing the two directly would
    # fail on the documented default. A values-pinned tag is the user's choice
    # and is asserted to render through unmodified.
    app_version, default_tag = read_default_tag(chart_dir)
    rendered_image = (main or {}).get("image") or ""
    last_path_element = rendered_image.rsplit("/", 1)[-1]
    rendered_tag = last_path_element.rsplit(":", 1)[-1] if ":" in last_path_element else ""
    checker.check(
        "the rendered main image tag tracks Chart.yaml appVersion",
        rendered_tag == (app_version if default_tag == "" else default_tag),
        f"appVersion={app_version!r} values image.tag={default_tag!r} rendered={rendered_image!r}",
    )


def mise_toml_from(configmaps: list[dict]) -> str:
    return next(
        (
            doc["data"]["mise.toml"]
            for doc in configmaps
            if "mise.toml" in (doc.get("data") or {})
        ),
        "",
    )


def check_toolenv(manifests: list[dict], checker: Checker) -> None:
    """The `mise.env` -> `mise.toml` `[env]` mapping, against a render made with
    toolchain env set:

        helm template nilchela charts/nilchela \
            --set mise.env.CARGO_HOME=/cache/cargo \
            --set mise.env.GOCACHE=/cache/go-build \
            > /tmp/toolenv.yaml
    """
    mise_toml = mise_toml_from(by_kind(manifests, "ConfigMap"))
    try:
        parsed = tomllib.loads(mise_toml)
    except tomllib.TOMLDecodeError as error:
        checker.check("mise.env renders a parseable mise.toml", False, str(error))
        return
    checker.check("mise.env renders a parseable mise.toml", True)
    checker.check(
        "mise.env renders as a mise.toml [env] table",
        isinstance(parsed.get("env"), dict),
        f"mise.toml={mise_toml!r}",
    )
    for name, value in (("CARGO_HOME", "/cache/cargo"), ("GOCACHE", "/cache/go-build")):
        checker.check(
            f"mise.env {name} renders into [env] as a string",
            (parsed.get("env") or {}).get(name) == value,
        )


def check_probes(manifests: list[dict], checker: Checker) -> None:
    """Probes, against a render with the Service **disabled**:

        helm template nilchela charts/nilchela \
            --set gateway.service.enabled=false \
            > /tmp/probes.yaml

    That combination is the interesting one, and the reason it is a contract
    rather than a comment: a kubelet probe comes from outside the container and
    targets the pod's own address, so a loopback-bound daemon fails its own
    probe — and a failing *liveness* probe then restarts a pod that was working
    perfectly. The probes must therefore fix the bind the same way the Service
    does, and they must do it on their own, with no Service in the render.
    Asserted here end to end: no Service, both probes rendered, bind off
    loopback.
    """
    checker.check(
        "no Service is rendered when gateway.service.enabled=false",
        not by_kind(manifests, "Service"),
    )
    statefulset = by_kind(manifests, "StatefulSet")
    if not statefulset:
        checker.check("a StatefulSet is rendered", False)
        return
    pod_spec = statefulset[0]["spec"]["template"]["spec"]
    main = container(pod_spec, "main")
    if not main:
        checker.check("main container exists", False)
        return

    readiness = main.get("readinessProbe") or {}
    http_get = readiness.get("httpGet") or {}
    checker.check(
        "the default readiness probe renders with the Service off",
        bool(readiness),
        f"probe={readiness!r}",
    )
    checker.check(
        "the readiness probe targets the gateway's /health",
        http_get.get("path") == "/health" and str(http_get.get("port")) == str(GATEWAY_PORT),
        f"httpGet={http_get!r}",
    )
    checker.check(
        "the default liveness probe renders with the Service off",
        bool(main.get("livenessProbe")),
    )

    env_map = {
        item.get("name"): item.get("value")
        for item in (main.get("env") or [])
        if isinstance(item, dict)
    }
    checker.check(
        "an enabled probe fixes the bind off loopback on its own",
        env_map.get("ZEROCLAW_gateway__host") not in (None, "", "127.0.0.1", "localhost"),
        f"ZEROCLAW_gateway__host={env_map.get('ZEROCLAW_gateway__host')!r}",
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rendered", help="output of `helm template`")
    parser.add_argument(
        "--toolenv-render",
        help="a second render made with `mise.env` set, for the [env] mapping",
    )
    parser.add_argument(
        "--probes-render",
        help="a third render made with a probe enabled and the Service disabled",
    )
    parser.add_argument("--chart-dir", default="charts/nilchela")
    parser.add_argument("--release-name", default="nilchela")
    parser.add_argument(
        "--repo-root",
        default=None,
        help=(
            "where the root LICENSE-MIT / LICENSE-APACHE / NOTICE live "
            "(default: derived from --chart-dir)"
        ),
    )
    parser.add_argument(
        "--check-package",
        action="store_true",
        help=(
            "also assert the licence files inside a real `helm package` archive "
            "(needs helm on PATH and the chart dependencies resolved)"
        ),
    )
    args = parser.parse_args(argv)
    repo_root = args.repo_root or os.path.dirname(
        os.path.dirname(os.path.abspath(args.chart_dir))
    )

    print(f"chart contract: {args.chart_dir} -> {args.rendered}\n")
    checker = Checker()
    print(f"licence integrity: {args.chart_dir} <-> {repo_root}")
    check_licenses(repo_root, args.chart_dir, checker)
    if args.check_package:
        print("licence integrity: packaged artifact")
        check_packaged_licenses(repo_root, args.chart_dir, checker)
    print()
    run_checks(load_manifests(args.rendered), args.chart_dir, checker)
    if args.toolenv_render:
        print(f"mise.env mapping: {args.toolenv_render}\n")
        check_toolenv(load_manifests(args.toolenv_render), checker)
    if args.probes_render:
        print(f"probes: {args.probes_render}\n")
        check_probes(load_manifests(args.probes_render), checker)
    return checker.report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
