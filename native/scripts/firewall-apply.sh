#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
load_config

TCP_MSS=${TCP_MSS:-1240}

nft delete table inet "${NFT_TABLE}" 2>/dev/null || true
nft -f - <<EOF_NFT
table inet ${NFT_TABLE} {
    chain forward_mangle {
        type filter hook forward priority mangle; policy accept;
        iifname "${TRANSIT_IF}" oifname "${WARP_IF}" tcp flags syn \
            tcp option maxseg size set ${TCP_MSS} \
            counter comment "WARP_MSS_CLAMP"
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        iifname "${TRANSIT_IF}" ct state invalid \
            counter drop comment "WARP_INVALID_DROP"

        iifname "${TRANSIT_IF}" meta nfproto ipv6 \
            counter drop comment "WARP_IPV6_TRANSIT_DISABLED"

        iifname "${TRANSIT_IF}" ip saddr != ${TRUSTED_SOURCE_CIDR} \
            counter drop comment "WARP_UNTRUSTED_SOURCE"

        # This rule remains loaded even when the tunnel/routing service stops.
        iifname "${TRANSIT_IF}" oifname != "${WARP_IF}" \
            counter drop comment "WARP_KILL_SWITCH"

        iifname "${TRANSIT_IF}" oifname "${WARP_IF}" \
            ip saddr ${TRUSTED_SOURCE_CIDR} \
            counter accept comment "WARP_TRANSIT_ACCEPT"

        iifname "${WARP_IF}" oifname "${TRANSIT_IF}" \
            ct state established,related \
            counter accept comment "WARP_RETURN_ACCEPT"
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${WARP_IF}" ip saddr ${TRUSTED_SOURCE_CIDR} \
            counter masquerade comment "WARP_MASQUERADE"
    }
}
EOF_NFT

log "Scoped nftables kill switch and NAT loaded in table inet ${NFT_TABLE}."
