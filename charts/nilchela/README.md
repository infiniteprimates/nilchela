# nilchela Helm chart

Deploys [nilchela](https://github.com/infiniteprimates/nilchela) — the thin
ZeroClaw dev image that installs `mise`-managed toolchains at runtime — as a
single-replica StatefulSet with its volumes, its `mise.toml` ConfigMap, the
ownership model the image expects, and a ClusterIP Service in front of the
ZeroClaw gateway.

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
  under `app-template:`. The Service this chart renders is app-template's, too.
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

The image makes four promises. The chart exists mostly to keep them — plus one
it has to keep on the image's behalf, because a volume mount breaks it:

| Promise | Where it lives | Why |
|---|---|---|
| The installer runs as root | `initContainers.install-tools` (`runAsUser: 0`) | `/tools` is root-owned; that is what lets the agent mount it read-only |
| The agent runs non-root | `containers.main` (`runAsUser: 65534`) | the image's posture, preserved |
| The agent cannot write `/tools` | `persistence.tools.advancedMounts` | this is the one mount needing per-container modes: RW for the installer, `readOnly: true` for the agent |
| No `fsGroup` | nowhere — by omission | an fsGroup hands the agent's group write access to `/tools`; with a root-owned installer that is an escalation path into the toolchains the agent is about to execute |
| The gateway binds all interfaces | `containers.main.env` (`ZEROCLAW_gateway__host`, `ZEROCLAW_gateway__allow_public_bind`) | the PVC at `/zeroclaw-data` shadows the image's baked `config.toml`, so the daemon otherwise falls back to `host = 127.0.0.1` — and the Service would front a port nothing outside the pod can dial |

The last row is not an image promise; it is the chart undoing an accident it
causes. See [The Service, and the bind it needs](#the-service-and-the-bind-it-needs).

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

## The Service, and the bind it needs

`zeroclaw daemon` supervises an HTTP gateway, so the pod *does* take inbound
traffic. The chart renders one **ClusterIP** `Service` on `42617` in front of it.

- **ClusterIP, and only ClusterIP.** Reaching the gateway from inside the
  cluster is the useful default; publishing it beyond the cluster is a decision
  this chart deliberately does not make. No Ingress, no TLS, no LoadBalancer.
- **Ingress/TLS are the consumer's call** — and if you add them, terminate
  authentication there, because of the `/health` note below.
- **The Service is only useful because the bind is fixed.** The chart's PVC at
  `/zeroclaw-data` **shadows** the image's baked
  `/zeroclaw-data/.zeroclaw/config.toml`, so the daemon starts from schema
  defaults (`[gateway] host = 127.0.0.1`) and would listen on loopback only —
  and the Service would front a port nothing outside the pod can dial. Two
  schema-mirror env vars on the main container move it to `0.0.0.0`:

  ```yaml
  app-template:
    controllers:
      main:
        containers:
          main:
            env:
              ZEROCLAW_gateway__host: "0.0.0.0"
              ZEROCLAW_gateway__allow_public_bind: "true"
  ```

  `ZEROCLAW_<dotted path, . → __>` is applied *after* config load and masked
  back out of anything the daemon saves, so it sets the running bind without
  writing a file into the data volume. An unresolvable `ZEROCLAW_` path is a
  hard startup error, so a typo fails loudly instead of silently reverting to
  loopback. `allow_public_bind` only silences the daemon's "binding to all
  interfaces" warning; it does **not** make the gateway public — the Service
  `type` does that, and it is `ClusterIP`.

  Disable the Service (`app-template.service.main.enabled: false`) and drop
  these two vars together: loopback plus `kubectl port-forward` is the tighter
  posture, and a fixed bind with no Service is strictly worse than either.

> **`/health` is unauthenticated.** It returns `status`, `paired`,
> `require_pairing` and a runtime health snapshot (component registry + uptime)
> with no auth at all. The dashboard and `/api/*` honour the gateway's
> pairing/TLS posture; `/health` does not. Inside a cluster that is acceptable —
> which is exactly why `ClusterIP` is the default. The moment you put an Ingress
> in front of this Service, terminate auth there before anything reaches
> `/health`.

### No probes — still deliberate

app-template adds none by default and this chart does not either. The gateway
*does* have `/health`, so a probe is now possible — it was not, and older copies
of this document said otherwise. What remains true is that neither probe is
right for every consumer:

- Without a probe, the pod reports **Ready as soon as the container is
  Running**, so `helm install --wait` returning success says nothing about
  whether the agent works.
- A liveness probe restarts a pet pod — a restart drops in-flight agent work,
  and an agent wedged on a model call still answers liveness. Restarting it
  should be a deliberate choice, not a default.
- Probes do not cover `initContainers`, so a cold `mise install` runs entirely
  before the main container exists.

If you want one, a **readiness** HTTP probe on `/health` is the safe shape
(`app-template.controllers.main.containers.main.probes.readiness`) — the
unauthenticated endpoint that makes it a poor public URL is what makes it a good
probe target.

---

## Upgrading app-template

The dependency is pinned exactly, not ranged, because app-template's values
schema is versioned and a minor bump can rename or restructure keys. Read
[the upgrade notes](https://bjw-s-labs.github.io/helm-charts/docs/app-template/upgrades/)
before bumping, change the version in `Chart.yaml`, rebuild the dependency, and
run the contract test — it will catch a pod model that silently changed shape.

No `Chart.lock` is committed yet because it can only be generated by Helm.
`helm dependency build` writes one; commit it with the next dependency change.
