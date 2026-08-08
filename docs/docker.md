# Docker deployment

## Scope

The Docker edition targets Docker Engine on an Ubuntu Linux host. The container uses `network_mode: host` so it can see and control the host interfaces, routes, WireGuard interface, and nftables namespace.

The container is not privileged. It receives only:

```yaml
cap_add:
  - NET_ADMIN
  - NET_RAW
```

## Why a host bootstrap is required

A transparent gateway must affect the Linux host routing and forwarding path before user traffic is accepted. The setup script therefore installs a small host component that:

- Persists the transit address when necessary.
- Enables IPv4 forwarding and loose reverse-path filtering.
- Loads `warp_docker_guard`, an nftables table that drops transit packets unless their output interface is `warp0`.
- Configures persistent seven-day system journal retention.
- Starts Docker and the Compose project.

The host guard is independent of the container. A stopped, crashed, or unhealthy container cannot make transit traffic fall back to the normal uplink.

## Install

```bash
sudo ./setup.sh --mode docker
```

Or directly:

```bash
sudo ./docker/setup.sh
```

## Runtime files

```text
docker/generated/warp-gateway.env   generated host-specific configuration
docker/state/wgcf-account.toml      WARP account identity, excluded from Git
docker/state/wgcf-profile.conf      generated profile, excluded from Git
```

Back up `docker/state` securely if the same WARP identity must be preserved.

## Operations

```bash
cd docker
docker compose ps
docker compose logs -f gateway
docker compose exec gateway /app/bin/status.sh
docker inspect warp-egress-gateway --format '{{.State.Health.Status}}'
journalctl CONTAINER_TAG=warp-egress-gateway --since "7 days ago" --no-pager
```

The container writes one structured passive monitor sample per minute. `AUTO_RECOVER=false` is the default in version 0.3.2 so incident evidence is retained before any optional tunnel restart.

## Stop and remove

`docker compose down` stops the runtime but deliberately leaves the host kill switch installed.

```bash
sudo ./docker/uninstall.sh
```

Use `--purge-state` only when the WARP identity should be deleted.

## Platform limitation

Docker Desktop on Windows and macOS runs Docker Engine inside a VM and does not expose the physical host's Layer-3 forwarding path in the same way as Docker Engine on Linux. Use a Linux VM or bare-metal Linux Docker host for this edition.
