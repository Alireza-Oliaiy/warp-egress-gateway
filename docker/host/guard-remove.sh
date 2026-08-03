#!/usr/bin/env bash
set -Eeuo pipefail
nft delete table inet warp_docker_guard 2>/dev/null || true
