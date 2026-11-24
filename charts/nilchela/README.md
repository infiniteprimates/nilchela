# nilchela Helm chart

Deploys [nilchela](https://github.com/infiniteprimates/nilchela) — the thin
ZeroClaw dev image that installs `mise`-managed toolchains at runtime — as a
single-replica StatefulSet with its volumes, its `mise.toml` ConfigMap, the
ownership model the image expects, and a ClusterIP Service in front of the
ZeroClaw gateway.

- Chart version: `0.2.3` · App version: `0.1.2` (the image tag it deploys)
- Requires Kubernetes `>= 1.31` (the render library's floor) and Helm 3.x

Consume the published artifact — no clone, no `repo add`:

```bash
helm install nilchela oci://ghcr.io/infiniteprimates/charts/nilchela --version <version>
```

Or from a clone, which is the path for working on the chart itself:

```bash
helm dependency build charts/nilchela
helm install nilchela charts/nilchela
```

The chart is pushed to GHCR as an OCI artifact by
[`.github/workflows/nilchela-chart-publish.yaml`](../../.github/workflows/nilchela-chart-publish.yaml)
on every merge to `main` whose `Chart.yaml` version is not already in the
registry, and a published version is immutable. GHCR creates the package
**private** on first push — set its visibility to public in the package
settings, or nobody outside the org can pull it.

Run it with the release name `nilchela` and the resource names come out short:
StatefulSet `nilchela`, PVCs `nilchela-tools` / `nilchela-cache` /
`nilchela-data`. Any other release name yields `<release>-nilchela` and
`<release>-nilchela-<volume>`.

---

## The public interface belongs to this chart

One file is yours; the other three are the chart's, and only the first is the
interface:

| File | Role |
|---|---|
| `values.yaml` | the surface — nilchela concepts only. The one file a consumer reads and writes |
| `values.schema.json` | the chart's guard on that surface: rejects unknown or malformed keys before render |
| `templates/_translate.tpl` | maps those values onto the shape the render library reads |
| `templates/resources.yaml` | calls `bjw-s.common.loader.all` with a context built from the translation |

`values.schema.json` is not a second copy of the surface. It is the chart's
*enforcement* of it — a second description of the same key set, whose only job is
to turn an unknown or malformed key into a render error instead of a silent
no-op. It is maintained chart-side and has to track `values.yaml` key for key,
and it already carries keys no consumer ever sets (the `common` bookkeeping Helm
injects for the library dependency). If the two disagree, the schema is what
runs.

The chart writes no Kubernetes YAML of its own. StatefulSet, PVCs, ConfigMap,
Service and ServiceAccount are rendered by
[bjw-s `common`](https://bjw-s-labs.github.io/helm-charts/) —
the **library** chart — pinned exactly. What this chart owns is the vocabulary
the user writes, and every invariant that vocabulary has to preserve.

Why it is built this way: Helm merges subchart values **before** render, so a
chart that depends on `app-template` as a subchart cannot translate its own
values into the subchart's. There is no hook for it — the dependency's schema
*is* the parent's public API, and stays that way. Depending on the library
instead turns rendering into a call this chart makes, which is what leaves room
for a translation.

What that buys:

- **No vocabulary leak.** `image.tag`, `tools.go`, `volumes.required.tools.size`. No
  collections, no `advancedMounts`, no `main` as a magic key, no `app-template:`
  nesting, and no ConfigMap key that has to be escaped on the command line.
- **Fail-fast input.** Unknown or malformed keys fail the render. A chart that
  exposes its dependency's schema cannot do this — the renderer simply ignores
  what it does not recognise.
- **Invariants are structural, not prose.** There is no `ingress:` key to set, no
  `defaultPodOptions` to reach through, and no wholesale `app-template:` spread.
  See *What is deliberately not exposed*.
- **The dependency's versioning is our problem, not the user's.** A `common`
  bump changes this chart's internals; the values a user already wrote keep
  their shape. The chart's test stack — see *Testing and validation* — is the
  regression gate for that claim.

What it costs — read this before you file a bug about it:

- **We own a translation layer.** `templates/_translate.tpl` is real code with
  real bug surface, and it is the only thing standing between a user's values
  and the rendered manifests.
- **The surface is narrower than `app-template`'s.** Ingress, ServiceMonitor,
  extra containers and sidecars are not reachable until they are designed in.
  That is the trade, and it was made deliberately.
- **A different flavour of coupling.** We depend on the library's *template* API
  (`bjw-s.common.loader.all` and the context it expects), not on a documented
  values interface. So `common` is pinned exactly, and the full test stack runs
  on every bump.

---

## What the defaults encode

The image makes four promises. The chart exists mostly to keep them — plus two of
its own, both consequences of mounting a volume:

| Promise | Where it lives | Why |
|---|---|---|
| The installer runs as root | `_translate.tpl` → `install-tools` (`runAsUser: 0`) | `/tools` is root-owned; that is what lets the agent mount it read-only |
| Superseded tool versions do not accumulate | `_translate.tpl` → `install-tools`, one script: `mise install`, then `mise --yes prune --tools` | the tools volume is retained across releases and mounted read-only into the agent, so nothing in the pod can reclaim a version a pin bump orphaned — or a tool dropped from `tools` entirely. The prune is unscoped because the volume is the chart's alone; and it fails the rollout rather than warning |
| The agent runs non-root | `_translate.tpl` → `main` (`runAsUser: 65534`) | the image's posture, preserved |
| The agent cannot write `/tools` | `_translate.tpl` → `advancedMounts.main.{install-tools,main}` | the one mount needing per-container modes: RW for the installer, `readOnly: true` for the agent |
| No `fsGroup` | nowhere — by omission | an fsGroup hands the agent's group write access to `/tools`; with a root-owned installer that is an escalation path into the toolchains the agent is about to execute |
| A nested extra mount is writable by the agent | `_translate.tpl` → `prepare-mounts`, rendered only when an extra path is nested | the kubelet creates a missing mount point as `root:root`, and creates one per container — so the directories under an extra mount appear after every init container has exited and the non-recursive chown is already past. The chart creates and chowns that chain itself |
| The gateway binds all interfaces | derived from `gateway.service.enabled` | the PVC at `/zeroclaw-data` shadows the image's baked `config.toml`, so the daemon otherwise falls back to `host = 127.0.0.1` — and the Service would front a port nothing outside the pod can dial |

Note the column: four of those live in the translation, not in configuration.
There is no value a user can set that moves the ownership split, because getting
it wrong is not a preference — a single mount mode for both containers is the
failure mode where each container gets its own empty volume and the product
silently has no toolchains.

The last two rows are not image promises; they are the chart undoing accidents it
causes — a mount it makes, and the mount points the kubelet makes for it. See
[The Service, and the bind it needs](#the-service-and-the-bind-it-needs).

Because a pod-level `runAsNonRoot: true` combined with a container-level
`runAsUser: 0` is a hard kubelet error, the ownership split is per-container —
there is no pod-level `securityContext` anywhere in this chart.

`tests/chart_contract.py` asserts every row of that table against a real
`helm template` render, on every PR. `tests/values_surface_test.yaml` covers the
translation's own template logic (which conditional or default produced each
value) under `helm unittest`, which needs no cluster.

---

## Configuration

`mise.toml` is the single source of truth for what the image installs, and the
translation renders it into a ConfigMap mounted at `/config/mise.toml` from one
values key: `mise`. It is named after the file it produces, and keyed the way that
file is written — `mise.tools` is its `[tools]` table, `mise.env` is its `[env]`
table. (The top-level `env` further down is a different thing: the *container's*
environment, set by Kubernetes.)

**The chart ships no toolchain pins.** Nothing installs until you add a
`[tools]` entry, which also means a fresh install is a valid install. Which
tools an agent needs is deployment policy; a version chosen by the chart would
be wrong for someone.

```bash
helm upgrade --install nilchela charts/nilchela --set mise.tools.go=1.27.1
```

```yaml
mise:
  tools:
    go: "1.27.1"
    rust:
      version: "1.83.0"
      profile: default        # a map renders as the [tools.rust] sub-table
  env:                        # rendered into mise.toml's [env]
    CARGO_HOME: /cache/cargo        # Rust — crate registry + build artifacts
    GOMODCACHE: /cache/go/pkg/mod   # Go — module cache
    GOCACHE: /cache/go-build        # Go — build cache
    NPM_CONFIG_CACHE: /cache/npm    # Node — npm cache
    UV_CACHE_DIR: /cache/uv         # Python — uv cache
    PIP_CACHE_DIR: /cache/pip       # Python — pip cache
env:                          # pod-level env for the daemon, verbatim
  ZEROCLAW_models__default: "..."
```

That is the common set, one entry per toolchain that keeps a cache of its own.
Each variable belongs to a single tool, so take only the lines for the tools you
pinned.

Pin exactly. A range makes `mise` resolve over the network on every start, which
throws away the warm-volume fast path the retained `/tools` claim exists to
provide.

Backend-qualified tool names work as written — `pipx:trash-cli`, `cargo:resvg`,
`npm:some-cli`. A colon is not legal in a TOML bare key, so the translation quotes
those keys in the rendered `mise.toml`; keys that can stand bare are left bare, so
the document reads the way you would write it.

See [`mise.toml.example`](../../mise.toml.example) for the full reference —
per-tool options, Rust targets and components, dist mirrors.

Toolchain environment is declared the same way, and for the same reason. The
cache variables are per tool (`CARGO_HOME`, `GOMODCACHE`, `NPM_CONFIG_CACHE`,
`UV_CACHE_DIR`, …), mise cannot infer them, and which ones you need follows from
which tools you installed — so `mise.env` is empty by default and the chart ships
no defaults for it either. What you put there is rendered into `mise.toml`'s
`[env]` table, which the image's `mise exec` entrypoint applies to the daemon and
everything it spawns; `mise env` reports the same values. Pointing those
variables at `/cache` is what keeps disposable registries off the durable
`/zeroclaw-data` volume.

Do not restate the image's own mise bootstrap variables in `mise.env`
(`MISE_DATA_DIR`, `MISE_RUSTUP_HOME`, `MISE_CACHE_DIR`, …). mise reads those
before `mise.toml` exists; restating them here desynchronises the paths it
already installed into.

### Pruning superseded versions

`mise install` only ever adds. When you bump a pin, the version it replaces stays
on the tools volume — which is retained across `helm uninstall`, and mounted
read-only into the agent, so nothing inside the pod can reclaim it. The installer
init container therefore runs `mise prune` straight after `mise install`, in the
same container and the same shell script:

```text
set -eu
mise install
mise --yes prune --tools
```

Three properties of that line are deliberate:

- **After the install, never before.** `mise prune` decides what is unused from
  the config files mise has *tracked*. Run first, against a volume with no tracked
  config yet, it would delete every toolchain it can see.
- **Unscoped, deliberately.** `/tools` is the chart's, not the agent's: the agent
  mounts it read-only, so this init container is the only writer, and it writes
  only what this config says. Everything on the volume is therefore the chart's to
  delete — which is what reclaims a tool you dropped from `tools` entirely, not
  just a version you bumped. `--tools` is still passed, because without it prune
  also forgets the *tracked config links*, including the one that keeps your
  declared versions alive for the next prune.
- **It fails the rollout.** Stale versions cost disk; a prune that quietly does
  nothing costs disk *silently*, and the volume fills up over releases with nobody
  watching. `set -eu` means a failed prune fails the init container, so the bad
  state is visible at deploy time. `--yes` is what makes the prune unattended —
  without it, `mise prune` stops to confirm each version and an init container has
  no TTY.

There is no mute switch. A chart is declarative: a version that leaves `tools`
leaves the volume. `mise ls --prunable` inside the pod shows what the next install
will remove.

The prune runs even against an empty `tools` table. Declaring no tools means the
volume should hold none; a missing pin is a state to converge on, not a reason for
the chart to guess, and getting the toolchains back is an edit to `tools`.

### Overriding the rest

The whole surface:

```yaml
image:
  repository: ghcr.io/infiniteprimates/nilchela
  tag: "0.1.2"                # empty means .Chart.AppVersion
  pullPolicy: IfNotPresent

mise:                          # rendered into the chart's mise.toml
  tools: {}                    # pin exactly, no ranges; pruning is automatic
  env: {}                      # per-tool cache variables, see Configuration

env: {}                        # the container's own env, verbatim

upgrade:
  configMigrate:
    enabled: true              # run `zeroclaw config migrate` before the daemon

resources:
  requests: { cpu: 100m, memory: 512Mi }
  # no limits by default: this is a build host, and a limit turns a slow
  # `cargo build` into an OOMKill

volumes:
  # The image's contract: the three volumes it expects at /tools, /cache and
  # /zeroclaw-data. The chart owns those paths, so `path` is refused. `size`
  # creates a claim and the chart defaults it (10Gi / 5Gi / 10Gi); `existingClaim`
  # adopts one you already have instead; `type: emptyDir` trades the claim for a
  # pod-local directory — see *Ephemeral volumes*.
  required:
    tools: {}                    # or: size: 20Gi / existingClaim: zeroclaw-tools
    cache: {}
    data:  {}

  # What you add. The key IS the mount path.
  extra: {}
    # media: { existingClaim: media, readOnly: true }
    #
    # One directory, several sources, one mount — the kubelet refreshes a mounted
    # Secret in place, so a rotating credential needs no restart, unlike `env`.
    # agent-secrets:
    #   type: projected
    #   path: /var/run/agent-secrets/<agent>
    #   defaultMode: "0444"
    #   sources:
    #     - secret: { name: zeroclaw-<agent>-app-token, items: [ { key: token, path: gh/token } ] }
    #
    # Eight source types are available: persistentVolumeClaim, secret, configMap,
    # projected, emptyDir, ephemeral, hostPath, image. `nfs` is not one of them —
    # its export path and the mount path would both be called `path` — and neither
    # is `custom`, because a raw passthrough is what this surface replaces.

gateway:
  service: { enabled: true, type: ClusterIP, port: 42617 }

scheduling:                    # passed through to the pod spec
  nodeSelector: {}
  tolerations: []
  affinity: {}
```

Every claim the chart creates is annotated `helm.sh/resource-policy: keep` — the
three `required` ones and any `volumes.extra` claim — so `helm uninstall` leaves
them behind on purpose. Deleting an orphaned claim is a deliberate one-liner;
recovering `/zeroclaw-data` after an accidental uninstall is not. To reattach one
after an uninstall, set `volumes.required.<volume>.existingClaim` — all three take
it, as an alternative to `size` — and note that an adopted claim is left
unannotated, because it is not ours to say what happens to it next. The claim is
used as-is: its size and storage class are whatever it already had, and this chart
does not resize or re-provision it. A volume set to `type: emptyDir` creates no
claim at all, so there is nothing to retain — see *Ephemeral volumes*.

Claim names are pinned: a created claim is `<release>-<volume>` (`nilchela-tools`,
`nilchela-cache`, `nilchela-data`) and an `extra` claim is `<release>-<key>`,
whatever else is in the release. The bjw-s library appends the identifier only when
a chart renders *more than one* claim, so without the pin, flipping two of the three
`required` volumes to `emptyDir` would rename the survivor to the bare release name
— a new, empty claim created beside the retained one it orphaned. The pin makes the
name independent of the count; a `volumes.extra` claim behaves the same way, so a
name never moves under a values change that only removes claims.

### Ephemeral volumes

`volumes.required.<volume>.type: emptyDir` backs that path with a pod-local
directory instead of a claim. It is opt-in and never the default: the default
install is the durable one, and a default that makes `/zeroclaw-data` ephemeral is
a default that loses state on the first restart. Three cases reach for it — a
cluster with no storage provisioner (the default install renders three claims, and
without a provisioner none of them bind), a throwaway install, and `/cache`, which
is disposable by definition.

What each one costs:

| Volume | Ephemeral means | Cost |
|---|---|---|
| `tools` | the toolchains | the init container re-installs them on every pod restart — this is the cold install the chart was built around |
| `cache` | disposable caches | re-downloaded as they are used; not a cold install, because the toolchains live in `/tools` |
| `data` | the daemon's state | gone on every restart, and `keep` is moot — no claim is created to keep |

Under `type: emptyDir` no claim field may be named: `size`, `storageClass` and
`existingClaim` each fail at render, naming the key and the field, because there
is no claim to configure. The mirror holds too — `medium` and `sizeLimit` are
refused on a claim. `sizeLimit` is the one worth reaching for: an emptyDir with no
limit is bounded only by the node's disk, so a runaway build can fill it. `medium:
Memory` puts the directory in RAM and counts against the container's memory limit,
which makes `sizeLimit` the thing that keeps it from being the pod's OOMKill.

### What is deliberately not exposed

- **Ingress, TLS, LoadBalancer.** Reaching the gateway from inside the cluster
  is the useful default; publishing it is a decision this chart does not make.
  If you add an Ingress, the `/health` route is the one to think about — see
  *The Service, and the bind it needs*.
- **Probes are the consumer's budget, and configured here.** `probes.readiness`
  and `probes.liveness` ship on; all three take `enabled`, plus `type`, `path`,
  `port` and a raw k8s `spec`. See *Probes* below for what each one does to the
  pod — and for where it is the wrong tool.
- **Extra containers, volumes, sidecars, ServiceMonitor, `defaultPodOptions`.**
  Reachable in `app-template`, withheld here: each one is a way to make the pod
  model untrue while looking configured.
- **A wholesale `app-template:` spread.** It stays out for testability, not
  taste: a value that skips the translation is a value nothing in this chart
  reads, so `tests/chart_contract.py` cannot assert it, and the guarantees above
  go back to being prose.

Power-user features are added as **relations**, not escape hatches. The Service
is the worked example: `gateway.service.enabled` *derives* the bind override, so
one switch cannot disagree with itself.

---

## The Service, and the bind it needs

`zeroclaw daemon` supervises an HTTP gateway, so the pod *does* take inbound
traffic. The chart renders one **ClusterIP** `Service` on `42617` in front of it.

- **ClusterIP, and only ClusterIP.** Reaching the gateway from inside the
  cluster is the useful default; publishing it beyond the cluster is a decision
  this chart deliberately does not make. No Ingress, no TLS, no LoadBalancer.
- **Ingress/TLS are the consumer's call** — and if you add them, read the
  `/health` note below: pairing guards the dashboard and `/api/*`, and never
  guards that route. An **Ingress** is the conventional choice; an
  **`HTTPRoute` (Gateway API)** is tidier if you
  already run it, because the route matches a subpath directly and rewrites it
  with a `URLRewrite` / `ReplacePrefixMatch` filter — no capture-group
  backreferences, which is exactly what an nginx `rewrite-target` needs for the
  same job. Serving the gateway under a subpath also wants
  `env: { ZEROCLAW_gateway__path_prefix: "/<prefix>" }`, so the routes the
  daemon serves sit where the proxy looks.
- **The Service is only useful because the bind is fixed, and the switch that
  fixes it is the same switch that creates the Service.** The chart's PVC at
  `/zeroclaw-data` **shadows** the image's baked
  `/zeroclaw-data/.zeroclaw/config.toml`, so the daemon starts from schema
  defaults (`[gateway] host = 127.0.0.1`) and would listen on loopback only —
  and the Service would front a port nothing outside the pod can dial. So
  `gateway.service.enabled` also emits two schema-mirror env vars on the main
  container:

  ```yaml
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

  Set `gateway.service.enabled: false` and both vars go with it: loopback plus
  `kubectl port-forward` is the tighter posture, and a fixed bind with no
  Service is strictly worse than either.

> **`/health` is unauthenticated.** It returns `status`, `paired`,
> `require_pairing` and a runtime health snapshot (component registry + uptime)
> with no auth at all. The dashboard and `/api/*` honour the gateway's
> pairing/TLS posture (`require_pairing` defaults to `true`; the guard is a
> bearer token); `/health` does not. Inside a cluster that is acceptable — which
> is exactly why `ClusterIP` is the default. If you put an Ingress in front of
> this Service, that route is the one to think about: pairing covers the dashboard
> and `/api/*`, and it never covers `/health`.

> **The ZeroClaw web UI must not be exposed to the open internet.** The
> dashboard is an agent control surface — daemon config, workspace personality
> files, pairing and device management, agent loops. What guards it is zeroclaw's
> own **pairing** (`gateway.require_pairing`, on by default), so there is no
> separate auth layer to add here; pairing is the mechanism, and it is a bearer
> token over plain HTTP, because this chart terminates no TLS. Reach the UI from
> inside the cluster or over a VPN.

### Probes — on by default, budget exposed

A daemon that cannot answer `/health` is not doing its job, so the default
install carries a readiness and a liveness probe against it:

```yaml
probes:
  port: 42617          # shared default; a per-probe `port` overrides it
  readiness:
    enabled: true
    # path: /health      # default
    # type: HTTP         # default; HTTPS, TCP, GRPC, AUTO also accepted
    spec: { initialDelaySeconds: 5, periodSeconds: 10, timeoutSeconds: 3, failureThreshold: 3 }
  liveness:
    enabled: true
    spec: { initialDelaySeconds: 30, periodSeconds: 20, timeoutSeconds: 5, failureThreshold: 6 }
  startup:
    enabled: false
```

What each one does to this pod, and where it is the wrong tool:

| Probe | On failure | Good for | Wrong for |
|---|---|---|---|
| readiness | the pod leaves the Service endpoints; nothing restarts | any consumer whose clients reach the pod through the Service | `kubectl port-forward`, which ignores readiness — the probe is not on that path at all; and a single replica has nowhere to move traffic to, so unready means refused connections instead of a readable error |
| liveness | the container restarts | a daemon that has stopped serving: wedged event loop, dead listener, a process that will not recover on its own | a container that is merely *busy*. This one runs the agent's builds, and the kubelet's probe shares the CPU with them |
| startup | restarts the container unless it passes once, then never runs again | a consumer whose daemon startup is genuinely slow | here: `mise install` runs in an *init container*, so the main container's boot is short and `initialDelaySeconds` covers it |

**Why liveness is on, and why its budget is loose.** Restarting is the right
answer to a gateway that has stopped answering: while it is not answering,
nothing is progressing that a restart would interrupt. What is *not* safe is a
tight budget. `/health` is served by the same process that supervises the agent's
work, so on a pod compressing a `cargo build` that handler can be scheduled late
without anything being broken — and a probe that restarts a healthy-but-busy pod
is worse than no probe, because the restart interrupts the build and the rebuild
runs under the same load. Six failures × 20s is two minutes of unbroken silence:
a wedged daemon, not a busy one. To narrow it to "the listener is gone", set
`probes.liveness.type: TCP` — the kernel answers a TCP probe from the accept
queue, so it survives handler starvation, and you give up noticing a wedged
handler in exchange.

**Why a restart, not just an alert.** A failing `/health` is not a degraded
service to be watched; it is the daemon's whole interface — dashboard, REST API,
the route the agent is driven through — not answering. This is a single-replica
pod, so the failure has to be repaired by a person either way, and the repair they
would reach for is `kubectl rollout restart`. An alert does not replace that
restart, it reports it: `restartCount` rising and `CrashLoopBackOff` are the alert
conditions, and a restart that cannot fix its cause backs off loudly instead of
retrying forever. The option that actually loses agent time is leaving a wedged
pod in place and waiting for someone to read a page. Where liveness is genuinely
the wrong tool is a pod that is *busy* rather than broken — which is why the
budget is two minutes, not two failures.

**Readiness is the cheap one.** It cannot destroy work, and it is what makes
`helm install --wait` mean anything: with no probe, the pod reports Ready the
moment the container is Running. Its cost is the blackhole above — one replica,
no other endpoint to serve.

**Enabling any probe also fixes the bind.** This is the part worth knowing: a
probe is issued by the kubelet from outside the container and targets the pod's
own address, not loopback, so a loopback-bound daemon fails its own probe — and a
failing *liveness* probe then restarts a pod that was working perfectly. So
`probes` emits the same two schema-mirror env vars `gateway.service` does
(`ZEROCLAW_gateway__host=0.0.0.0` and `ZEROCLAW_gateway__allow_public_bind=true`),
for the same reason and with the same consequence: the pod's IP becomes reachable
from anywhere in the cluster, which is why the chart's own arm of this stays
ClusterIP.

Shape notes:

- The target is `/health` on the gateway port — the unauthenticated endpoint that
  makes a poor public URL and a good probe target.
- `spec` is a raw k8s probe spec merged over the derived probe, so
  `initialDelaySeconds` / `periodSeconds` / `timeoutSeconds` / `failureThreshold` /
  `successThreshold` all work. The timings above are the chart's judgement, not a
  k8s default — every one of them is yours to move.
- Probes do not cover `initContainers`, so a cold `mise install` runs entirely
  before the main container exists — it cannot be what your probe waits for, and
  it is why no startup probe ships.
- `tests/chart_contract.py` asserts both ends: the default render carries
  readiness and liveness on `/health` and no startup probe, and a render with
  `gateway.service.enabled=false` still emits the off-loopback bind.

---

## Testing and validation

Four layers, cheapest first. Each covers something the others cannot; where they
overlap it is in spirit, not in reach.

| # | Layer | Tool | What only it catches |
|---|---|---|---|
| 1 | Lint | `helm lint` | chart conventions and template syntax |
| 2 | Schema validation | `kubeconform -strict` | rendered manifests against the Kubernetes API — a deprecated or malformed kind that would otherwise render green |
| 3 | Template logic | `helm unittest` (`tests/values_surface_test.yaml`) | which conditional, default or loop produced each rendered value, with no cluster |
| 4 | Pod model | `tests/chart_contract.py` | relations *between* rendered locations, which a path-against-literal assertion cannot express |

Layers 3 and 4 are not substitutes for each other. `helm unittest` asserts that
a path equals a literal; the contract test asserts that `main` and
`install-tools` mount the *same* volume at `/tools`, that dropping `dependsOn`
would reorder the installers, and that the rendered image tag still tracks
`Chart.yaml`'s `appVersion`. Those are the invariants this chart exists to
encode — and they are the class of bug the render gate has already caught once.

To run the whole stack locally:

```bash
helm dependency build charts/nilchela
helm lint charts/nilchela
helm unittest charts/nilchela
helm template nilchela charts/nilchela --namespace nilchela > /tmp/rendered.yaml
kubeconform -strict -summary -kubernetes-version 1.31.0 /tmp/rendered.yaml
uv run --with pyyaml python3 charts/nilchela/tests/chart_contract.py \
  /tmp/rendered.yaml --chart-dir charts/nilchela
```

`kubeconform` is run at `1.31.0` — the floor `Chart.yaml` claims, which is the
`common` library's own floor — and without `-ignore-missing-schemas`, so an
unknown kind fails loudly rather than being skipped.

Deliberately not on that list: `ct install` against a kind cluster. Two costs
are specific to *this* chart — the image installs its toolchains at runtime over
the network, so a per-PR install is slow, flaky, and tests the network more than
the chart; and kind ships no storage provisioner while the chart renders three
retained PVCs that would never bind. That belongs on a schedule or behind a
label, not on every PR.

---

## Upgrading across a ZeroClaw release

Most releases need nothing from you: change nothing and the chart deploys the new
image on the same values. A release that bumps the **config schema** is the
exception, and ZeroClaw v0.9.0 is one — it moves the config to schema version 4
and the release notes ask the operator to run `zeroclaw config migrate` once.

Left to hand that step is a quiet failure. Until the rewrite happens the daemon
does load the old file, but it migrates it in memory only, so `config set`,
`config init`, `config patch` and `models set` all refuse — and nothing on the
pod says so unless you happen to try one.

So the chart performs it. `upgrade.configMigrate.enabled` (default `true`)
renders a `config-migrate` init container that runs `zeroclaw config migrate`
against the data volume:

- **After `fix-ownership`, before `install-tools`.** The rewrite is the agent's,
  so it runs as the agent (uid 65534) once the volume has been handed over; it
  sorts first among the non-root steps so a config that cannot be migrated fails
  in seconds rather than after a toolchain install.
- **Invoking the binary directly**, not through the image's `mise exec` entrypoint
  — a schema rewrite needs no toolchain, so it must not wait on one.
- **A no-op where there is nothing to do.** A fresh volume has no
  `config.toml` yet, and a volume already at the current schema reports "already
  at current schema version"; both exit 0. The recurring cost is one container
  start per pod.

An **init container rather than a Helm `pre-upgrade` hook**, because a hook runs
while the outgoing pod's daemon is still up and holding its own copy of the
config — it can save over the file you just migrated. An init container runs when
nothing else owns the volume, and it also covers a plain rollout, a node drain or
a pod restart, none of which a Helm hook sees.

**Read the backup before you delete it.** The first rewrite of a version 3 file
keeps the original as `config.toml.backup` next to it on the data volume
(`/zeroclaw-data/.zeroclaw/config.toml.backup`): owner-only, written once, a
byte-for-byte copy of the file as it stood, and readable by an older binary. It
also still holds every retired key, so it holds whatever the config held — which
under the default `secrets.encrypt = true` is ciphertext, not plaintext. The
migration never decrypts to write it, so the copy inherits the original's
encryption exactly. The limit is the key, not the copy: the master key lives at
`.zeroclaw/.secret_key`, in the same directory on the same volume, so that
encryption protects a backup that leaves the volume from someone who does not
have the volume — it does not protect against someone who already does. A
deployment that sets `secrets.encrypt = false` gets a plaintext backup. Delete it
once you no longer need to downgrade, and treat the volume as secret-bearing
either way.

**To go back to an older image, the file moves first, and the pod is out of the
way while it does.** An 0.8.x daemon does not reject a version 4 file: its
resilient loader catches the version bail and starts on `Config::default()` with
the whole-config degradation sentinel set — a daemon with no agents, no channels
and no credentials, which is quieter and worse than a crash loop. And the claim is
`ReadWriteOnce`, so a second pod cannot mount it while the StatefulSet pod holds
it. Both are avoided by this order:

1. `kubectl scale statefulset nilchela --replicas=0` — nothing is running against
   the old file, and the claim is free. The scale stays at zero across step 3: the
   chart renders `replicas:` with no value, so the API defaults it on create, and
   every revision carries the same null — Helm's three-way merge sees no change
   and emits no patch for that field, leaving an out-of-band scale alone. (Reasoned
   from Helm's merge semantics, not rehearsed on a cluster. It is also why the
   scale-up is its own step — if that empty `replicas:` is ever "tidied up" into
   `replicas: 1`, this step stops being optional and starts being a race.)
2. Restore the file from a one-shot pod on the same claim, in the release
   namespace:

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: config-restore
     namespace: nilchela        # the release namespace; the claim is namespaced
   spec:
     restartPolicy: Never
     securityContext: { runAsUser: 65534, runAsGroup: 65534, runAsNonRoot: true }
     containers:
       - name: restore
         image: ghcr.io/infiniteprimates/nilchela:0.1.2
         command: ["cp", "-p",
                   "/zeroclaw-data/.zeroclaw/config.toml.backup",
                   "/zeroclaw-data/.zeroclaw/config.toml"]
         volumeMounts: [{ name: data, mountPath: /zeroclaw-data }]
     volumes:
       - name: data
         persistentVolumeClaim: { claimName: nilchela-data }
   ```

   ```sh
   kubectl -n nilchela delete pod config-restore --ignore-not-found
   kubectl -n nilchela apply -f config-restore.yaml
   kubectl -n nilchela logs -f config-restore     # exits 0 when the copy lands
   ```

   The delete comes first because a Pod is immutable: re-running the recipe
   without it fails on the existing pod instead of copying again. It has to run as
   uid 65534, since the file is owner-only and the volume is already the agent's.
   If the backup is gone, the config is not recoverable from the cluster — a
   version 4 file cannot be downgraded byte-for-byte, only restored from that copy.
3. `helm upgrade … --set image.tag=<old> --set upgrade.configMigrate.enabled=false`
   — or `helm rollback` to the 0.2.1 revision, which has neither the container
   nor the flag. The switch matters on this chart version because the container
   would otherwise re-migrate the restored v3 file back to v4 on start.
4. `kubectl scale statefulset nilchela --replicas=1`.

Downgrading an *unmigrated* data volume is the quiet case: `config migrate` has
existed since at least 0.8.7, where it is a no-op at schema 3, so pinning an older
tag before the migration is harmless.

Three situations where this switch matters:

- **A config that migrate refuses.** Migrate validates the result before it
  replaces the file, so a config that can no longer validate fails the container,
  and therefore the pod, with the reason in the init container's log
  (`kubectl logs <pod> -c config-migrate`). That is deliberate — better than a
  daemon that starts and cannot be edited — but set
  `upgrade.configMigrate.enabled=false` if you need the pod up while you fix the
  file.
- **A downgrade.** See the rollback above: the file and the image move together,
  and the switch is what stops the file being migrated straight back.
- **A config outside `/zeroclaw-data/.zeroclaw`.** Three routes reach that state
  and the init container sees none of them: `env.ZEROCLAW_CONFIG_DIR` on the agent
  container, `mise.env` (it lands in `mise.toml`'s `[env]`, which `mise exec`
  applies to the daemon — and the init container bypasses `mise` entirely), or a
  `HOME` override, which is the one the base image actually relies on
  (`ENV HOME=/zeroclaw-data`). The migration would then rewrite the default path
  while the daemon reads another. This surface has no way to pass any of them to
  an init container, so in that case set `upgrade.configMigrate.enabled=false` and
  run `zeroclaw config migrate` against the real path once, by hand.

---

## Upgrading the render library

`common` is pinned exactly, not ranged, because its template API is versioned
and a minor bump can rename or restructure what the loader renders. To bump it:
change the version in `Chart.yaml`, run `helm dependency build charts/nilchela`,
and run the full test stack (*Testing and validation*) against the new render. A
pod model that silently changed shape is exactly what layer 4 exists to catch.

`Chart.lock` is committed with the dependency; regenerate it with
`helm dependency build`.
