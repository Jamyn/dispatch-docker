# Security Policy

## Scope

This repository is a Docker/Compose bootstrap for [Netflix Dispatch](https://github.com/Netflix/dispatch) — roughly 700 lines of shell, Compose, and CI config with no application code of its own. Reports in scope here are about *this* repo: `install.sh` (including secret generation and Postgres credential handling), `docker-compose.yml`, and the GitHub Actions workflows under `.github/workflows/`.

Vulnerabilities in the Dispatch application itself belong in [Jamyn/dispatch](https://github.com/Jamyn/dispatch), the actively maintained fork this repo's build context is pinned to — report them privately at [github.com/Jamyn/dispatch/security/advisories/new](https://github.com/Jamyn/dispatch/security/advisories/new). The Netflix upstream was archived (read-only) on 2025-09-01 and has no security response path; the fork's `main` and its latest release are what get fixed.

## Reporting a vulnerability

Report privately via GitHub: **[github.com/Jamyn/dispatch-docker/security/advisories/new](https://github.com/Jamyn/dispatch-docker/security/advisories/new)** (also reachable from this repo's **Security and quality** tab → **Report a vulnerability**). Please don't open a public issue for a suspected vulnerability. This is a single-maintainer, best-effort project with no SLA, but reports are read and acted on.

## Supported versions

Bug and security reports are accepted against the **latest tagged release** (`v*`, see [Releases](https://github.com/Jamyn/dispatch-docker/releases)) and the current `main` tip only — the same applies to `main` in [Jamyn/dispatch](https://github.com/Jamyn/dispatch). Older releases receive no fixes; upgrade to the latest release before reporting. Fixes land on `main` and ship in the next release.
