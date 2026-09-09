# Security Policy

## Supported versions

nilchela is a thin, opinionated build recipe on top of the official
[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) base image. We publish
the in-progress `latest` tag plus semver tags; only the most recent semver
release and the tip of the default branch are actively maintained.

## Reporting a vulnerability

Please **do not** open a public issue for security-sensitive findings.

Report vulnerabilities privately to the maintainers via GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
feature on this repository, or to the maintainer contact published by the
[Infinite Primates](https://github.com/infiniteprimates) org.

Please include:

- A description of the issue and its impact
- Steps to reproduce, or a proof-of-concept if available
- Affected versions

## Scope

Security issues in the nilchela recipe itself (Dockerfile, `mise.toml`, install
scripts) are in scope. Vulnerabilities in the upstream dependencies — the
[ZeroClaw](https://github.com/zeroclaw-labs/zeroclaw) base image,
[mise](https://github.com/jdx/mise), or the toolchains installed at runtime —
should be reported to their respective upstream projects.

## What to expect

- An acknowledgment within a reasonable window.
- A good-faith effort to triage and, for in-scope issues, publish a fix.
- This is a small project with no SLAs; if you need a guaranteed response
  window, consider maintaining a hardened internal fork.

## Defense-in-depth note

Because the image runs on clusters and installs toolchains at runtime, treat
every toolchain version bump as a supply-chain decision: pin exactly,
prefer official sources, and pair with a `mise.lock` (see
[`mise.toml.example`](mise.toml.example)) for reproducible installs.
