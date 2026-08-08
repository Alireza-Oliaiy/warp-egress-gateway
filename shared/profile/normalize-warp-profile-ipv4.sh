#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE=${1:-}
[[ -n ${PROFILE} ]] || { echo "Usage: $0 PROFILE" >&2; exit 2; }
[[ -r ${PROFILE} ]] || { echo "WARP profile not readable: ${PROFILE}" >&2; exit 1; }

ipv4_address=$(awk -F= '
  /^[[:space:]]*Address[[:space:]]*=/ {
    n=split($2, parts, ",")
    for (i=1; i<=n; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
      if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
        print parts[i]
        exit
      }
    }
  }
' "${PROFILE}")

[[ -n ${ipv4_address} ]] || {
  echo "WARP profile does not contain an IPv4 Address entry." >&2
  exit 1
}

tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT

awk -v ipv4_address="${ipv4_address}" '
  /^[[:space:]]*Address[[:space:]]*=/ {
    print "Address = " ipv4_address
    next
  }
  /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
    print "AllowedIPs = 0.0.0.0/0"
    next
  }
  { print }
' "${PROFILE}" > "${tmp}"

cat "${tmp}" > "${PROFILE}"

# This gateway release intentionally routes IPv4 only. Ensure wg-quick will not
# try to configure IPv6 addresses on hosts where IPv6 is disabled.
if grep -Eq '^[[:space:]]*(Address|AllowedIPs)[[:space:]]*=.*:' "${PROFILE}"; then
  echo "IPv6 remained in Address/AllowedIPs after profile normalization." >&2
  exit 1
fi
