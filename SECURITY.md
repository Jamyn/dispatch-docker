# Security Policy

## Scope

This repository is a Docker/Compose bootstrap for [Netflix Dispatch](https://github.com/Netflix/dispatch) — roughly 700 lines of shell, Compose, and CI config with no application code of its own. Reports in scope here are about *this* repo: `install.sh` (including secret generation and Postgres credential handling), `docker-compose.yml`, and the GitHub Actions workflows under `.github/workflows/`.

Vulnerabilities in the Dispatch application itself belong in [Jamyn/dispatch](https://github.com/Jamyn/dispatch), the fork this repo's build context is pinned to. That fork mirrors [Netflix/dispatch](https://github.com/Netflix/dispatch), which was archived (read-only) on 2025-09-01, so no active security response should be expected there either — treat application-level findings as informational rather than something with a maintenance path.

## Reporting a vulnerability

Report privately via GitHub: **[github.com/Jamyn/dispatch-docker/security/advisories/new](https://github.com/Jamyn/dispatch-docker/security/advisories/new)** (also reachable from this repo's **Security and quality** tab → **Report a vulnerability**). Please don't open a public issue for a suspected vulnerability. This is a single-maintainer, best-effort project with no SLA, but reports are read and acted on.

## Supported versions

There is no versioned release of this repository; `master` is the only branch that matters. Fixes land there directly.
