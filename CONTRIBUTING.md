# Contributing

Thanks for contributing to **nilchela**. This is a small, focused project, so the bar is simple: keep the two design invariants intact, and certify that you have the right to submit what you send.

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

## Sign off your commits (DCO)

There is **no CLA**. Contributions are accepted under the [Developer Certificate of Origin 1.1](https://developercertificate.org/) — the same `inbound = outbound` certification the Linux kernel uses. You keep the copyright in your contribution; you certify that you had the right to submit it.

Certify by adding a `Signed-off-by` line to every commit. Git does it for you:

```bash
git commit -s -m "chart: raise the Kubernetes floor to 1.31"
```

which appends, from your configured `user.name` and `user.email`:

```text
Signed-off-by: Your Name <you@example.com>
```

Use your real name and a reachable address. The sign-off is a first-person statement about a contribution you made — do not sign off on someone else's behalf. (The one narrow exception is the maintainer certifying an agent-authored branch; see [Remediation](#remediation).)

A pull request fails the `DCO` check if any commit in it is missing a valid sign-off. [Remediation](#remediation) is how that gets fixed without rewriting history.

The full text you are certifying:

```text
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

## Automation

Part of this project is written by AI agents (the ZeroClaw dev team) working under the maintainer's authority. They are tooling, not authors, and hold no copyright — see [`AUTHORS.md`](AUTHORS.md). That has two consequences for how commits are made:

- **Agents never add `Signed-off-by`.** The sign-off is a first-person legal certification and a non-person cannot make one. Every agent-authored change is certified by a human — the maintainer — through the remediation path below.
- **Agent commits carry an `Assisted-by:` trailer** naming the agent, instead:

  ```text
  Assisted-by: zeroclaw-tony[bot] <329726292+zeroclaw-tony[bot]@users.noreply.github.com>
  ```

  A trailer discloses; it does not certify. Keep it to one line: GitHub's squash-message builder generates a `Co-authored-by:` line for every distinct author on a branch, so a branch that mixes identities republishes all of them into `main`'s history.

## Remediation

A **remediation commit** retroactively adds a missing sign-off. It is a new commit, so history is not rewritten and no one's work is disturbed. Both forms are enabled in [`.github/dco.yml`](.github/dco.yml).

### Individual

Authored by the same person as the commits it covers:

```text
DCO remediation commit for Your Name <you@example.com>

I, Your Name <you@example.com>, hereby add my Signed-off-by to this commit: <SHA>
I, Your Name <you@example.com>, hereby add my Signed-off-by to this commit: <SHA>

Signed-off-by: Your Name <you@example.com>
```

### Third-party

Authored by the maintainer on behalf of the failing commit's author. This is the normal path for agent-authored pull requests:

```text
Third-party DCO remediation commit for <author>

On behalf of <author>, I, <maintainer>, hereby add my Signed-off-by to this commit: <SHA>

Signed-off-by: <maintainer>
```

Only sign off for someone whose authority you actually hold — you cannot certify a contributor you have no relationship with.

A remediation commit moves the pull request's head, and the ruleset dismisses stale reviews on push. Approve **after** it lands, not before.

> A failed DCO check also offers a **Set DCO to pass** override button. It is an escape hatch for a one-off; prefer a remediation commit, because the remediation commit is the certification recorded in git history, while the override lives only in GitHub's audit log.

## Submitting changes

- Open an issue first for anything bigger than a small fix — the maintainers can tell you whether it conflicts with the invariants.
- Keep PRs focused: one change, clearly described.
- Version pins (`MISE_VERSION`, tool versions) are deliberate; explain why you're bumping one.

## Style

- TOML, Dockerfile, YAML and Python are the primary formats. Follow the existing comment style — the files are self-documenting by design.
- YAML examples for *consumers* live in the consuming repo; this repo ships the image recipe and the reference chart under [`charts/nilchela`](charts/nilchela).

The key design decisions (the `[tools]` vs `[env]` split, the storage/ownership model, the no-`fsGroup` rationale) are explained inline in [`Dockerfile`](Dockerfile) and the README.

## Maintainers

Maintained by the [Infinite Primates](https://github.com/infiniteprimates) org, on behalf of the copyright holder named in [`AUTHORS.md`](AUTHORS.md). It layers on [ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) — give them a look.
