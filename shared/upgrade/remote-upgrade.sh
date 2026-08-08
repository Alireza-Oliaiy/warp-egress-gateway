#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_URL=${WARP_GATEWAY_REPOSITORY_URL:-https://github.com/Alireza-Oliaiy/warp-egress-gateway.git}
REF=${WARP_GATEWAY_UPGRADE_REF:-latest}
MODE=auto
ASSUME_YES=false
DRY_RUN=false
SKIP_TESTS=false

usage() {
  cat <<'USAGE'
Fetch a WARP Egress Gateway release and run its safe upgrader.

Usage:
  sudo warp-gateway-upgrade [options]

Options:
  --ref REF          Git branch/tag, or latest. Default: latest tagged release.
  --mode MODE        auto, native, or docker. Default: auto.
  --yes              Do not prompt before the maintenance window.
  --dry-run          Detect and validate without changing the host.
  --skip-tests       Skip source-tree validation tests.
  -h, --help         Show this help.

Production tip:
  The default resolves the highest vX.Y.Z tag. Use --ref main only when intentionally testing unreleased code.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF=${2:?Missing value after --ref}; shift 2 ;;
    --mode) MODE=${2:?Missing value after --mode}; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ ${EUID} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ ${MODE} =~ ^(auto|native|docker)$ ]] || { echo "Invalid mode: ${MODE}" >&2; exit 2; }
[[ ${REF} =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ && ${REF} != *..* && ${REF} != */. && ${REF} != ./* ]] \
  || { echo "Invalid ref: ${REF}" >&2; exit 2; }

if ! command -v git >/dev/null 2>&1; then
  echo "git is required for remote upgrades. Install git first." >&2
  exit 1
fi

workdir=$(mktemp -d /tmp/warp-egress-upgrade.XXXXXX)
cleanup() { rm -rf "${workdir}"; }
trap cleanup EXIT

if [[ ${REF} == latest ]]; then
  REF=$(git ls-remote --tags --refs "${REPOSITORY_URL}" 'refs/tags/v*' \
    | awk '{sub("refs/tags/", "", $2); print $2}' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    | tail -n1 || true)
  [[ -n ${REF} ]] || { echo "No semantic-version release tags were found. Use --ref main only for an intentional unreleased upgrade." >&2; exit 1; }
fi

die() { echo "[upgrade-bootstrap] ERROR: $*" >&2; exit 1; }

resolve_requested_ref() {
  local ref=$1 remote_ref
  if [[ ${ref} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    remote_ref="refs/tags/${ref}"
  else
    remote_ref="refs/heads/${ref}"
  fi

  RESOLVED_OID=$(git ls-remote --exit-code "${REPOSITORY_URL}" "${remote_ref}" \
    | awk -v wanted="${remote_ref}" '$2 == wanted { print $1; exit }')
  [[ ${RESOLVED_OID} =~ ^[0-9a-fA-F]{40}$ ]] \
    || die "Requested ref ${ref} could not be resolved exactly."
  RESOLVED_REF=${remote_ref}
}

validate_checked_out_version() {
  local version_file=$1 checked_out_version expected_version
  [[ -r ${version_file} ]] || die "Downloaded upgrade source is missing VERSION."
  checked_out_version=$(<"${version_file}")
  [[ ${checked_out_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Malformed VERSION in downloaded upgrade source."

  if [[ ${REF} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    expected_version=${REF#v}
    [[ ${checked_out_version} == "${expected_version}" ]] \
      || die "Requested tag ${REF} does not match downloaded VERSION ${checked_out_version}."
  fi
}

resolve_requested_ref
echo "[upgrade-bootstrap] Fetching ${REPOSITORY_URL} ref ${REF} (${RESOLVED_OID})."
git clone --quiet --no-checkout --depth 1 "${REPOSITORY_URL}" "${workdir}/repo"
git -C "${workdir}/repo" fetch --quiet --depth 1 origin "${RESOLVED_OID}"
git -C "${workdir}/repo" checkout --quiet --detach "${RESOLVED_OID}"
[[ $(git -C "${workdir}/repo" rev-parse HEAD) == "${RESOLVED_OID}" ]] \
  || die "Downloaded source does not match resolved ${RESOLVED_REF}."
validate_checked_out_version "${workdir}/repo/VERSION"

args=(--mode "${MODE}")
[[ ${ASSUME_YES} == true ]] && args+=(--yes)
[[ ${DRY_RUN} == true ]] && args+=(--dry-run)
[[ ${SKIP_TESTS} == true ]] && args+=(--skip-tests)

bash "${workdir}/repo/upgrade.sh" "${args[@]}"
