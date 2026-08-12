# Contributing to dispatch-docker

This is a single-maintainer, best-effort project — an independently
maintained continuation of Netflix's archived `dispatch-docker`. Contributions
are welcome; response time is not guaranteed.

## Before you start

- **This repo has no application code.** It's Compose, `install.sh`, and
  deployment CI — roughly 700 lines of shell/Compose/config. Changing what
  Dispatch itself does belongs in
  [`Jamyn/dispatch`](https://github.com/Jamyn/dispatch) instead; this repo
  only builds it at a pinned commit.
- For anything non-trivial, open an issue first to discuss the approach
  before writing code.
- Security vulnerabilities should **not** be filed as public issues — see
  [`SECURITY.md`](SECURITY.md).

## Development setup

There's no build step or test suite to install — this repo is validated by
running the actual scripts and Compose config:

```bash
bash -n install.sh                 # shell syntax
shellcheck install.sh              # shell lint
docker compose config              # Compose schema/resolution (needs .env)
./install.sh                       # full install/upgrade against a real Docker daemon
```

## Making changes

- Keep pull requests focused — one logical change per PR.
- `install.sh` must keep working on both macOS and Linux (see the `$OSTYPE`
  branches already in the script); don't introduce Linux-only or
  GNU-only assumptions.
- Use `docker compose` (space), not the legacy hyphenated `docker-compose` —
  Compose V1 is not supported.
- If you touch the build-context line in `docker-compose.yml`, verify a real
  build succeeds before opening the PR — it has broken silently before.

## Commit messages

Use a conventional prefix: `feat`, `fix`, `docs`, `refactor`, `test`,
`build`, `ci`, `chore`, `perf`, or `security`. Lowercase, short and factual:

```
fix: force TCP for the postgres readiness probe
```

**Every commit must be signed.** GitHub will reject unsigned commits on
`main` — see the required-signatures rule below.

## Pull requests

- Target `main`.
- Every commit must be signed (`required_signatures` is enforced on `main`);
  unsigned commits, including those from automation, cannot be merged.
- Apply at least one primary label: `bug`, `enhancement`, `documentation`,
  `maintenance`, `security`, `ci`, or `breaking-change` — this is required
  by `enforce-labels` and also drives the categorized release notes. Topic
  labels (`postgres`, `docker`, `compose`, `install`, `github-actions`, etc.)
  are optional.
- `actionlint` and `shellcheck` run on every PR; `postgres-install` (the real
  functional coverage) only runs on `workflow_dispatch` and version tags, so
  test install/upgrade paths locally before relying on CI to catch a
  regression.
- No approvals are required to merge; commits must be signed (GitHub-enforced
  via the branch ruleset). CI runs `enforce-labels`, `actionlint`,
  `shellcheck`, and `image-checks` on every PR.

## Reporting issues

Deployment, Compose, and installer issues belong in this repo's issue
tracker. Application bugs belong in
[`Jamyn/dispatch`](https://github.com/Jamyn/dispatch/issues). Suspected
vulnerabilities should go through
[GitHub security advisories](https://github.com/Jamyn/dispatch-docker/security/advisories/new)
instead of a public issue.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you're expected to uphold it.
