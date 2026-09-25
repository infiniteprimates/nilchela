# PROTOTYPE A — nilchela wrapped over the bjw-s `common` library

**Status: spike. Not for merge.** Unrendered: no `helm` binary was available where it was
written, so every template here is *unexecuted code*. The point of the prototype is to make the
mechanism concrete and to name exactly what must be verified.

## The idea

The shipping chart (`charts/nilchela`) depends on the published `app-template` chart **as a
subchart**, so its values live under `app-template:` and app-template's schema *is* the chart's
public API. Helm merges subchart values before render, so a parent cannot translate its own values
into a subchart's — which is why "wrap it" is impossible in that arrangement.

This prototype swaps the dependency to `common` (the **library** chart) and calls its loader itself:

| File | Role |
| --- | --- |
| `values.yaml` + `values.schema.json` | the native surface — nilchela concepts only, unknown keys rejected |
| `templates/_translate.tpl` | native values → the values shape the library renders from |
| `templates/resources.yaml` | `include "bjw-s.common.loader.all" $ctx` with a synthetic context |
| `templates/NOTES.txt` | install-time notes written against the *native* keys |

Three files carry the whole interface. The library never sees `image.tag`; it sees what the
translation hands it.

## Why it should work — from the library source, not from hope

At tag `app-template-5.1.0`, `charts/library/common/templates/`:

- `loader/_all.tpl` defines `bjw-s.common.loader.all`, which calls `loader.init` then `loader.generate`.
- `loader/_generate.tpl` opens with `{{- $rootContext := $ -}}` and renders every resource class
  (`render.pvcs`, `render.controllers`, `render.services`, `render.configMaps`, …) from **that
  context**.

`$` inside a `define` is the argument the caller passed. The library is therefore a renderer
resolved against whatever context it is handed — it does not reach for `.Values.app-template` or any
fixed key. That is the property this prototype depends on, and it is visible in the source.

## What this buys (testable against the shipping chart)

- **No vocabulary leak.** `image.tag`, `tools.go`, `storage.tools.size` — no collections, no
  `advancedMounts`, no `main` as a magic key, nothing to disambiguate.
- **The `mise\.toml` wart disappears.** Toolchains are a values map, so
  `--set tools.go=1.27.1` replaces `--set-file 'app-template.configMaps.config.data.mise\.toml=…'`.
- **`global.nameOverride` disappears.** Names come from `.Chart.Name` = `nilchela`, not from a
  leaf chart called `app-template`.
- **A relationship the old chart could only document:** `gateway.service.enabled` *derives* the
  `ZEROCLAW_gateway__host` override. One switch, instead of two settings that must be kept in
  agreement by hand.
- **Fail-fast input.** `additionalProperties: false` — a typo'd key is a render error. With the
  schema exposed, the library silently ignores keys it does not recognise.
- **Invariants stop being prose.** There is no `service:` or `probes:` key to set, and no
  `defaultPodOptions` for a user to reach, because `scheduling` maps to a closed subset.

## What is NOT verified

1. **`loader/_init.tpl`** (175 bytes) runs before `generate`. It must be read to confirm it
   normalises only the context it is given — and does not assume a subchart arrangement.
2. **Naming parity.** The wrapped chart must render the *same object names* as the shipping chart
   (`<release>-nilchela`, PVCs `<release>-nilchela-tools`/`-cache`/`-data`).
3. **`fromYaml` round-trip.** Types, quoting and multi-line `mise.toml` must survive the
   text → parse → render path. This is the fiddliest part of the design.
4. **ServiceAccount.** 5.x creates an unprivileged ServiceAccount by default; the wrapped chart must
   produce the same one.
5. **`_translate.tpl` correctness** — 100 lines of Go template, never executed.

## The spike that decides it

```sh
helm dependency update prototypes/common-wrap
helm template nilchela prototypes/common-wrap > /tmp/wrapped.yaml

# control: the shipping chart, same defaults
helm template nilchela charts/nilchela > /tmp/shipping.yaml
diff <(yq -P 'sort_keys(..)' /tmp/shipping.yaml) <(yq -P 'sort_keys(..)' /tmp/wrapped.yaml)
```

Byte-identical output (modulo the deliberately-removed `global.nameOverride`) is the acceptance
criterion — it proves the translation is faithful and becomes the regression test for every future
`common` bump. If the diff cannot be made empty, that is the finding, and it lands before any
rewrite.

## Recommendation if the spike passes

Promote to `charts/nilchela` as **0.1.0** (breaking), delete the app-template dependency, add a
migration table to the chart README, and add a `extra.volumes` / `extra.containers` passthrough as
an **allowlist** — never a wholesale `app-template:` spread, which would put the invariants back
into prose.
