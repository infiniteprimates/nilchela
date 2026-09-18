#!/usr/bin/env python3
"""Contract test for the nilchela chart — asserts the invariants the chart
exists to encode, against a live `helm template` render.

Why this exists: the chart is a wrapper, so most of its behaviour is
app-template's. What is *ours* is the pod model — root installer, non-root
agent, read-only /tools, split ownership, no fsGroup — plus the assumption that
app-template resolves `advancedMounts` for an initContainer by key. Neither the
Helm linter nor app-template's own values schema can check any of that. This
can, on every PR.

Deliberately dependency-light (PyYAML only) and read-only: it renders nothing,
it inspects what Helm produced.

Usage:
    helm template nilchela charts/nilchela > /tmp/rendered.yaml
    python3 charts/nilchela/tests/chart_contract.py /tmp/rendered.yaml \
        --chart-dir charts/nilchela --release-name nilchela
"""

from __future__ import annotations

import argparse
import sys

import yaml

AGENT_UID = 65534
TOOLS_PATH = "/tools"
CONFIG_PATH = "/config"
CACHE_PATH = "/cache"
DATA_PATH = "/zeroclaw-data"


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
    tag = (
        values.get("app-template", {})
        .get("controllers", {})
        .get("main", {})
        .get("containers", {})
        .get("main", {})
        .get("image", {})
        .get("tag")
    )
    return (
        str(app_version) if app_version is not None else None,
        str(tag) if tag is not None else None,
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

    # -- the StatefulSet has a serviceName, even with no Service defined.
    # app-template defaults it to the chart fullname; a StatefulSet without it
    # is rejected by the API server.
    checker.check(
        "StatefulSet sets spec.serviceName",
        bool(spec_of(statefulsets[0]).get("serviceName")),
    )

    # -- no Service. An agent host accepts no inbound traffic, so a Service
    # would be dead weight. Asserted rather than merely omitted: the absence
    # is a design decision, and one added `service:` key would undo it
    # silently.
    checker.check(
        "no Service is rendered (the agent host takes no inbound traffic)",
        not by_kind(manifests, "Service"),
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
        # This is the load-bearing app-template assumption: advancedMounts
        # addresses an initContainer by key.
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

    # -- drift guard: the chart's appVersion is the image tag it deploys.
    app_version, default_tag = read_default_tag(chart_dir)
    checker.check(
        "Chart.yaml appVersion matches the default image tag",
        app_version is not None and app_version == default_tag,
        f"appVersion={app_version!r} image.tag={default_tag!r}",
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rendered", help="output of `helm template`")
    parser.add_argument("--chart-dir", default="charts/nilchela")
    parser.add_argument("--release-name", default="nilchela")
    args = parser.parse_args(argv)

    print(f"chart contract: {args.chart_dir} -> {args.rendered}\n")
    checker = Checker()
    run_checks(load_manifests(args.rendered), args.chart_dir, checker)
    return checker.report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
