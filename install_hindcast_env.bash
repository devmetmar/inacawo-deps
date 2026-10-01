#!/bin/bash
# Install Miniforge into inacawo-deps (if missing), create required LO dirs for
# the current user, then create/update the hindcast conda env.
#
# Paths come from env (SST): source $DEPS_ROOT/env
#
# Usage:
#   bash $HOME/inacawo-deps/install_hindcast_env.bash
#   bash install_hindcast_env.bash --force-recreate   # remove + recreate hindcast
#
set -euo pipefail

DEPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${DEPS_ROOT}/env"

# Ensure CONDA_BASE targets this deps tree for install (ignore legacy fallback)
CONDA_PREFIX_DIR="${DEPS_ROOT}/miniforge3"
export CONDA_BASE="${CONDA_PREFIX_DIR}"
YML="${HINDCAST_YML:-${DEPS_ROOT}/hindcast.yml}"
ENV_NAME="${HINDCAST_ENV_NAME:-hindcast}"

FORCE_RECREATE=0
for arg in "$@"; do
  case "$arg" in
    --force-recreate) FORCE_RECREATE=1 ;;
    -h|--help)
      echo "Usage: $0 [--force-recreate]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${YML}" ]]; then
  echo "ERROR: missing ${YML}" >&2
  exit 1
fi
if [[ ! -d "${LO}/lo_tools" ]]; then
  echo "ERROR: missing ${LO}/lo_tools (needed for editable install)" >&2
  exit 1
fi

ensure_lo_dirs() {
  local d created=()
  echo "==> Ensuring LO directories for user '${USER_NAME}'"

  if [[ ! -d "/scratch" ]]; then
    echo "ERROR: /scratch does not exist on this host" >&2
    exit 1
  fi
  if [[ ! -d "${SCRATCH}" ]]; then
    echo "    creating ${SCRATCH}"
    mkdir -p "${SCRATCH}"
  fi

  # Scratch LO layout + shared hindcast base
  for d in \
    "${CAWO_INPUT}" \
    "${LO_DATA}" \
    "${LO_DATA}/grids" \
    "${LO_OUTPUT}" \
    "${LO_ROMS}" \
    "${CAWO_INPUT}/roms_forcing" \
    "${CAWO_HINDCAST_BASE}"
  do
    if [[ ! -d "${d}" ]]; then
      mkdir -p "${d}"
      created+=("${d}")
    fi
  done

  # LO_user lives in iht (git-tracked); only mkdir if parent preprocess exists
  if [[ -d "$(dirname "${LO_USER}")" && ! -d "${LO_USER}" ]]; then
    mkdir -p "${LO_USER}"
    created+=("${LO_USER}")
  fi

  if [[ ${#created[@]} -eq 0 ]]; then
    echo "    already present:"
  else
    echo "    created:"
    printf '      %s\n' "${created[@]}"
    echo "    layout:"
  fi
  printf '      %s\n' "${LO_DATA}" "${LO_DATA}/grids" "${LO_OUTPUT}" "${LO_ROMS}" "${CAWO_INPUT}/roms_forcing" "${CAWO_HINDCAST_BASE}"
  if [[ -d "${LO_USER}" ]]; then
    printf '      %s\n' "${LO_USER}"
  else
    echo "      (skip LO_user — clone inacawo-iht first; expected at ${LO_USER})"
  fi
}

detect_installer() {
  local uname_s uname_m
  uname_s="$(uname -s)"
  uname_m="$(uname -m)"
  case "${uname_s}_${uname_m}" in
    Linux_x86_64)  echo "Miniforge3-Linux-x86_64.sh" ;;
    Linux_aarch64) echo "Miniforge3-Linux-aarch64.sh" ;;
    Darwin_x86_64) echo "Miniforge3-MacOSX-x86_64.sh" ;;
    Darwin_arm64)  echo "Miniforge3-MacOSX-arm64.sh" ;;
    *)
      echo "ERROR: unsupported platform ${uname_s}/${uname_m}" >&2
      echo "Install Miniforge manually from https://github.com/conda-forge/miniforge" >&2
      exit 1
      ;;
  esac
}

install_miniforge() {
  local installer url tmp
  installer="$(detect_installer)"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer}"
  tmp="$(mktemp -d)"
  echo "==> Installing Miniforge to ${CONDA_PREFIX_DIR}"
  echo "    downloading ${url}"
  curl -fsSL -o "${tmp}/${installer}" "${url}"
  bash "${tmp}/${installer}" -b -p "${CONDA_PREFIX_DIR}"
  rm -rf "${tmp}"
  echo "==> Miniforge installed"
}

ensure_lo_dirs

if [[ ! -x "${CONDA_PREFIX_DIR}/bin/conda" ]]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download Miniforge" >&2
    exit 1
  fi
  install_miniforge
else
  echo "==> Found existing Miniforge at ${CONDA_PREFIX_DIR}"
fi

# shellcheck disable=SC1091
source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh"

if command -v mamba >/dev/null 2>&1; then
  CREATE=(mamba env create)
  UPDATE=(mamba env update)
  REMOVE=(mamba env remove)
else
  CREATE=(conda env create)
  UPDATE=(conda env update)
  REMOVE=(conda env remove)
fi

# Editable -e ./LO/lo_tools must resolve relative to DEPS_ROOT
cd "${DEPS_ROOT}"

if conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
  if [[ "${FORCE_RECREATE}" -eq 1 ]]; then
    echo "==> Removing existing env '${ENV_NAME}' (--force-recreate)"
    "${REMOVE[@]}" -n "${ENV_NAME}" -y
    echo "==> Creating env '${ENV_NAME}' from hindcast.yml"
    "${CREATE[@]}" -f "${YML}"
  else
    echo "==> Env '${ENV_NAME}' already exists — updating from hindcast.yml"
    echo "    (use --force-recreate for a clean rebuild)"
    "${UPDATE[@]}" -n "${ENV_NAME}" -f "${YML}" --prune
  fi
else
  echo "==> Creating env '${ENV_NAME}' from hindcast.yml"
  "${CREATE[@]}" -f "${YML}"
fi

echo
echo "==> Done."
echo "    CONDA_BASE=${CONDA_BASE}"
echo "    LO_DATA=${LO_DATA}"
echo "    LO_OUTPUT=${LO_OUTPUT}"
echo "    LO_ROMS=${LO_ROMS}"
echo "    CAWO_HINDCAST_BASE=${CAWO_HINDCAST_BASE}"
echo "    Activate with:"
echo "      source ${CONDA_BASE}/etc/profile.d/conda.sh"
echo "      conda activate ${ENV_NAME}"
echo "    Or from inacawo-iht:"
echo "      source \$HOME/inacawo-iht/setup_env.bash"
