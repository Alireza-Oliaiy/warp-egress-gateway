# Contributing

1. Create a focused branch.
2. Run `make test` before submitting a pull request.
3. Do not commit live profiles, account files, private keys, or real internal addressing.
4. Include failure-path testing for routing or firewall changes.
5. Keep Ubuntu 24.04 and shellcheck compatibility.

Pull requests changing the kill switch must demonstrate that transit traffic cannot use the management uplink while WARP is stopped.
