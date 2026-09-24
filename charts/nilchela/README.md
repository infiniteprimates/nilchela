# nilchela Helm chart

Deploys [nilchela](https://github.com/infiniteprimates/nilchela) — the thin
ZeroClaw dev image that installs `mise`-managed toolchains at runtime — as a
single-replica StatefulSet with its volumes, its `mise.toml` ConfigMap, and the
ownership model the image expects.

- Chart version: `0.0.0` · App version: `0.0.3` (the image tag it deploys)
- Requires Kubernetes `>= 1.28` (inherited from app-template) and Helm 3.x

```bash
helm dependency build charts/nilchela
helm install nilchela charts/nilchela
```

Run it with the release name `nilchela` and the resource names come out short:
StatefulSet `nilchela`, PVCs `nilchela-tools` / `nilchela-cache` /
`nilchela-data`. Any other release name yields `<release>-nilchela` and
`<release>-nilchela-<volume>`.

---

## This chart is a wrapper, and that is the whole design

It contains no Kubernetes templates. It declares
[bjw-s `app-template`](https://bjw-s-labs.github.io/helm-charts/docs/app-template/)
as a dependency, pins it, and supplies values in **app-template's** schema.
Everything app-template can do, this chart can do; nothing about resource
rendering is re-invented here.

What that buys:

- **No template maintenance.** Deployment/StatefulSet, PVC, ConfigMap and pod
  rendering are app-template's problem, not this repo's.
- **The whole app-template surface, for free.** Probes, extra containers,
  Ingress, NetworkPolicy, `defaultPodOptions` — all reachable by adding keys
  under `app-template:`.
- **Upgrades are a version bump** plus a re-read of app-template's upgrade
  notes, not a re-audit of hand-written manifests.

What it costs — read this before you file a bug about it:

- **Values are nested and verbose.** Overrides look like
  `app-template.controllers.main.containers.main.image.tag`, because Helm only
  passes values to a subchart under the dependency's name. There is no flat
  `image.tag` shorthand, and there cannot be: Helm cannot template the values
  it hands to a subchart, so the chart cannot narrow the API into something
  prettier.
- **Defaults are static.** `image.tag` cannot be `{{ .Chart.AppVersion }}` —
  inside the subchart that expression resolves against *app-template's* chart,
  not this one. The default tag is written out literally and
  `tests/chart_contract.py` fails the build if it drifts from `Chart.yaml`'s
  `appVersion`.
- **No IDE autocomplete.** app-template's `values.schema.json` describes the
  *un-nested* shape, so pointing `$schema` at it from the root of this chart's
  values would validate against the wrong structure. The comments in
  `values.yaml` are the documentation instead.

---

## What the defaults encode

The image makes four promises. The chart exists mostly to keep them:

| Promise | Where it lives | Why |
|---|---|---|
| The installer runs as root | `initContainers.install-tools` (`runAsUser: 0`) | `/tools` is root-owned; that is what lets the agent mount it read-only |
| The agent runs non-root | `containers.main` (`runAsUser: 65534`) | the image's posture, preserved |
| The agent cannot write `/tools` | `persistence.tools.advancedMounts` | this is the one mount needing per-container modes: RW for the installer, `readOnly: true` for the agent |
| No `fsGroup` | nowhere — by omission | an fsGroup hands the agent's group write access to `/tools`; with a root-owned installer that is an escalation path into the toolchains the agent is about to execute |

Because a pod-level `runAsNonRoot: true` combined with a container-level
`runAsUser: 0` is a hard kubelet error, the ownership split is per-container —
there is no pod-level `securityContext` anywhere in this chart.

`tests/chart_contract.py` asserts every row of that table against a real
`helm template` render, on every PR.

---

## Configuration

`mise.toml` is the single source of truth for what the image installs, and the
chart renders it into a ConfigMap mounted at `/config/mise.toml`.

**The chart ships no toolchain pins.** Nothing installs until you add a
`[tools]` entry, which also means a fresh install is a valid install. Which
tools an agent needs is deployment policy; a version chosen by the chart would
be wrong for someone.

```bash
# from a file...
helm upgrade --install nilchela charts/nilchela \
  --set-file 'app-template.configMaps.config.data.mise\.toml=./mise.toml'

# ...or inline
helm upgrade --install nilchela charts/nilchela \
  --set 'app-template.configMaps.config.data.mise\.toml=[tools]
go = "1.27.1"'
```

The backslash is not optional: `mise.toml` is a single ConfigMap key, and the
dot in it is not a path separator.

See [`mise.toml.example`](../../mise.toml.example) for the full reference —
per-tool options, Rust targets and components, dist mirrors. The running
container's environment is a function of that file: `[env]` is surfaced by
`mise`/shims, while `mise`'s own bootstrap variables are baked into the image
and must not be duplicated here.

### Overriding the rest

Any app-template value works under `app-template:`. The ones you are most
likely to want:

```yaml
app-template:
  controllers:
    main:
      containers:
        main:
          image:
            tag: "0.0.3"        # must match Chart.yaml appVersion
          resources: {}         # defaults: requests only, no limits
  persistence:
    data:
      size: 50Gi
    tools:
      # adopt a claim you already have instead of creating one:
      existingClaim: zeroclaw-tools
      # ...and keep its advancedMounts block
```

All three PVCs are annotated `helm.sh/resource-policy: keep`, so
`helm uninstall` leaves them behind on purpose. Deleting an orphaned claim is a
deliberate one-liner; recovering `/zeroclaw-data` after an accidental uninstall
is not.

---

## No Service, and no probes — deliberately

There is no `Service` and there are no probes. Assert both against the
`values.yaml` you ship rather than assuming them:

- **No Service.** An agent host accepts no inbound traffic, so there is nothing
  to front. The StatefulSet is still valid without one — Kubernetes requires
  `spec.serviceName` to be *populated*, not to resolve. Access is `logs` and
  `exec`.
- **No probes.** app-template adds none by default, and there is no HTTP
  endpoint to point one at. The consequences are worth stating rather than
  discovering: the pod reports **Ready as soon as the container is Running**,
  so `helm install --wait` returning success says nothing about whether the
  agent works; and a wedged agent is **never restarted** — supervision is
  manual. If you want either, add an exec probe under
  `app-template.controllers.main.containers.main.probes`; note that probes do
  not cover initContainers, so a cold `mise install` still runs entirely
  before the main container exists.

---

## Upgrading app-template

The dependency is pinned exactly, not ranged, because app-template's values
schema is versioned and a minor bump can rename or restructure keys. Read
[the upgrade notes](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/)
before bumping, change the version in `Chart.yaml`, rebuild the dependency, and
run the contract test — it will catch a pod model that silently changed shape.

No `Chart.lock` is committed yet because it can only be generated by Helm.
`helm dependency build` writes one; commit it with the next dependency change.
