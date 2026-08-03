#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MODE=""

usage() {
  cat <<'USAGE'
WARP Egress Gateway deployment selector

Usage:
  sudo bash setup.sh
  sudo bash setup.sh --mode native [native options]
  sudo bash setup.sh --mode docker [docker options]

Modes:
  native   Install directly on Ubuntu using systemd.
  docker   Run the WARP gateway runtime in Docker with a small host safety bootstrap.
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ ${1:-} == "--mode" ]]; then
  MODE=${2:?Missing value after --mode}
  shift 2
elif [[ ${1:-} == "native" || ${1:-} == "docker" ]]; then
  MODE=$1
  shift
fi

if [[ -z ${MODE} ]]; then
  echo "Select deployment mode:"
  echo "  1) Native Ubuntu/systemd"
  echo "  2) Docker Engine on Linux"
  read -r -p "Choice [1]: " choice
  case ${choice:-1} in
    1) MODE=native ;;
    2) MODE=docker ;;
    *) echo "Invalid choice." >&2; exit 2 ;;
  esac
fi

case ${MODE} in
  native) exec bash "${ROOT_DIR}/native/setup.sh" "$@" ;;
  docker) exec bash "${ROOT_DIR}/docker/setup.sh" "$@" ;;
  -h|--help) usage ;;
  *) echo "Unknown mode: ${MODE}" >&2; usage; exit 2 ;;
esac
