# Changelog

## 0.3.1 - 2026-08-03

- Fixed native and Docker status output so all three interfaces are displayed.
- Added Windows-safe publishing automation with Git executable-mode handling.
- Added `.gitattributes` to enforce LF line endings for shell scripts.
- Made the top-level selector invoke child installers through Bash, reducing dependency on extracted filesystem permissions.
- Updated documentation to use `sudo bash setup.sh`, which is resilient even before executable modes are restored.

## 0.3.0 - 2026-08-03

- Split the repository into `native/` and `docker/` deployment editions.
- Added a top-level deployment selector that asks for Native or Docker mode.
- Added a Docker Compose runtime using Linux host networking and scoped `NET_ADMIN`/`NET_RAW` capabilities.
- Added automatic Docker host discovery from the main IP and transit IP/CIDR.
- Added a persistent host-level Docker kill switch independent of container health.
- Added Docker health checks, automatic WARP recovery, state persistence, status commands, and uninstaller.
- Documented the Linux-only transparent Docker gateway constraint.

## 0.2.0 - 2026-08-03

- Added a two-address interactive setup wizard.
- Added automatic interface and default-gateway discovery.
- Added `/30` peer derivation and optional Netplan transit configuration.
- Preserved the fail-closed kill-switch design.

## 0.1.0 - 2026-08-03

- Initial reusable native Ubuntu gateway implementation.
