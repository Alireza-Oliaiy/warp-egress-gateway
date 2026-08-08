## Summary

Describe the behavior being changed and why.

## Safety / failure-path impact

- [ ] No change to routing/firewall/upgrade behavior.
- [ ] Failure-path behavior was reviewed and tested.
- [ ] Kill switch/host guard remains fail closed.

## Tests

- [ ] `make test`
- [ ] Runtime validation performed when applicable.

## Documentation

- [ ] README updated if top-level usage changed.
- [ ] Operator docs updated for lifecycle/command changes.
- [ ] `CHANGELOG.md` updated for user-visible behavior.
- [ ] Security/troubleshooting docs updated when applicable.

## Secrets

- [ ] No WireGuard private key, `wgcf-account.toml`, real credentials, or sensitive diagnostic bundle is included.
