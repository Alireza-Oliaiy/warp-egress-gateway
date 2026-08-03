#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
require_root
nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
log "Removed nftables table inet ${NFT_TABLE}."
