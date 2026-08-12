## Summary

<!-- What does this change do, and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Maintenance / refactor / dependency update
- [ ] Security fix
- [ ] Breaking change (requires operator action to upgrade)

## Checklist

- [ ] Commits are signed (required — see [CONTRIBUTING.md](../CONTRIBUTING.md))
- [ ] A primary label is applied (`bug`, `enhancement`, `documentation`,
      `maintenance`, `security`, `ci`, or `breaking-change`)
- [ ] `bash -n install.sh` and `shellcheck install.sh` pass if `install.sh`
      changed
- [ ] `docker compose config` resolves cleanly if `docker-compose.yml`
      changed
- [ ] Tested against a real Docker daemon (install/upgrade path), since
      `postgres-install` only runs on tags/`workflow_dispatch`, not on PRs
- [ ] README updated if operator-facing behavior changed

## Related issues

<!-- Closes #... -->
