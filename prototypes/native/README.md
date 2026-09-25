# PROTOTYPE B — nilchela as a self-contained chart

**Status: spike. Not for merge.** Unrendered: no `helm` binary was available where it was written,
so these templates are *unexecuted code*. The point is a concrete comparison with prototype A
(`prototypes/common-wrap`), not a finished chart.

## What it is

`apiVersion: v2` with `dependencies: []`. Six templates, all ours:

| Template | Object |
| --- | --- |
| `_helpers.tpl` | names and labels — three helpers, written out |
| `pvcs.yaml` | the three claims, `helm.sh/resource-policy: keep` |
| `configmap.yaml` | `mise.toml` from `.Values.tools` |
| `serviceaccount.yaml` | unprivileged SA, `automountServiceAccountToken: false` |
| `service.yaml` | conditional ClusterIP for the gateway |
| `statefulset.yaml` | pod model, mounts, init order, env |

`values.yaml` and `values.schema.json` carry **the same keys, defaults and validation rules as
prototype A's** — only the header comment and the schema title name the prototype. That is the
point: same interface on both, so any difference measured is a difference in implementation, and
the parity is asserted in `notes/validate_prototype_b.py` rather than asserted in prose.

## A vs B — the actual trade

**B is better at:**

- **The invariants are structural.** An init container's position *is* its order, so there is no
  `dependsOn` edge to lose. `/tools` is writable in exactly one container and read-only in the
  other, in one file. There is no pod-options passthrough to escape from.
- **No translation layer.** ~120 lines of translation are replaced by ~350 lines of manifest, but
  every line of B does one obvious thing. When it renders wrong, the bug is in the thing you are
  reading.
- **Small improvements become available.** `automountServiceAccountToken: false` is a one-line
  decision here. Under app-template you take the default.
- **Nothing to keep up with.** The chart is a function of the image's expectations. Today it
  depends on `common` 5.1.0 rendering AppTemplate-shaped values; B depends on Kubernetes.

**A is better at:**

- **Far less to own.** B is ~350 lines of YAML we maintain forever, including every future
  need — extra volume, sidecar, changed mount, a new probe that turns out to matter. app-template
  already has keys for most of them, with a test suite behind them.
- **A rendered-by-someone-else floor.** A's failure mode is a broken translation we wrote.
  B's failure mode is a manifest we wrote that renders perfectly and is still wrong — there is no
  reference implementation to diff against.
- **Upgrades.** Bumping `common` is a dependency bump plus the golden-diff test. Bumping B is a
  chart release we author.

## The question this decides

*Does app-template's rendering buy anything we would miss, once the interface no longer leaks?*

- If yes → **A**, and the golden diff is the proof.
- If no → **B**, and A's translation layer is dead weight kept only for a library we do not otherwise
  use.

If A hits the diff cleanly, the tie-break is lifecycle: B is ~350 lines we own forever, and A is one
translation file plus a library that is somebody else's problem. I lean A on that basis — but the
`common` library is not the last dependency we will take, and this is the moment to decide whether
"we vendored a renderer" is a design position we want.

## Verification

Static checks that ran: `notes/validate_prototype_b.py` (schema conformance, claim retention,
`/tools` mount modes, init-container order, absence of probes, Service gating).
The real check is the same as A's — render both and diff:

```sh
helm template nilchela prototypes/native > /tmp/native.yaml
helm template nilchela prototypes/common-wrap > /tmp/wrapped.yaml
diff <(yq -P 'sort_keys(..)' /tmp/native.yaml) <(yq -P 'sort_keys(..)' /tmp/wrapped.yaml)
```

An empty diff means the two are interchangeable and the decision is purely about what we want to
own. A non-empty diff is the interesting result: it says exactly what the library was doing for us.
