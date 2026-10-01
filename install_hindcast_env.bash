#!/bin/bash
# Install Miniforge into inacawo-deps (if missing), create required LO dirs for
# the current user, then create/update the hindcast conda env.
#
# Paths come from env (SST): source $DEPS_ROOT/env
#
# Usage:
#   bash $HOME/inacawo-deps/install_hindcast_env.bash
#   bash install_hindcast_env.bash --force-recreate
#   bash install_hindcast_env.bash --offline              # no network; use local cache
#   bash install_hindcast_env.bash --cache-dir /path      # override cache root
#   bash install_hindcast_env.bash --prefetch-miniforge   # download installer only
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

# Shared on-disk cache (Miniforge installer + conda pkgs) for offline / flaky network
CACHE_DIR="${CACHE_DIR:-/scratch/cawohdcst_ft2/inacawo-deps-cache}"

FORCE_RECREATE=0
OFFLINE=0
PREFETCH_ONLY=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --force-recreate       Remove and recreate the hindcast env
  --offline, --local     No downloads; use installer + pkgs under --cache-dir
  --cache-dir DIR        Cache root (default: ${CACHE_DIR})
  --prefetch-miniforge   Download Miniforge installer into cache, then exit
  -h, --help             Show this help

Cache layout:
  \$CACHE_DIR/miniforge/Miniforge3-*.sh
  \$CACHE_DIR/conda-pkgs/          # shared CONDA_PKGS_DIRS (populated on online installs)

Examples:
  # Normal (uses cache if present, else downloads into cache)
  bash $0

  # Network down: after one successful online install (or manual copy into cache)
  bash $0 --offline

  # Seed installer only
  bash $0 --prefetch-miniforge
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-recreate) FORCE_RECREATE=1 ;;
    --offline|--local|--local-only) OFFLINE=1 ;;
    --cache-dir)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --cache-dir needs a path" >&2; exit 1; }
      CACHE_DIR="$1"
      ;;
    --prefetch-miniforge) PREFETCH_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

CACHE_MINIFORGE="${CACHE_DIR}/miniforge"
CACHE_PKGS="${CACHE_DIR}/conda-pkgs"
mkdir -p "${CACHE_MINIFORGE}" "${CACHE_PKGS}"
export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-${CACHE_PKGS}}"

# ---- timing helpers ----
now_s() { date +%s; }
fmt_elapsed() {
  local secs="$1"
  printf '%dm%02ds' "$((secs / 60))" "$((secs % 60))"
}

T_START="$(now_s)"
T_MINIFORGE=0
T_ENV=0
MINIFORGE_ACTION="skipped"
ENV_ACTION="skipped"

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

fetch_miniforge_installer() {
  # Prints ONLY the installer path on stdout (captured by callers).
  # Human-readable status goes to stderr.
  local installer="$1"
  local dest="${CACHE_MINIFORGE}/${installer}"
  local url="https://github.com/conda-forge/miniforge/releases/latest/download/${installer}"

  if [[ -f "${dest}" ]]; then
    echo "    using cached installer: ${dest}" >&2
    printf '%s\n' "${dest}"
    return 0
  fi

  if [[ "${OFFLINE}" -eq 1 ]]; then
    echo "ERROR: --offline set but installer missing: ${dest}" >&2
    echo "       Copy ${installer} into ${CACHE_MINIFORGE}/ or run without --offline once." >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required to download Miniforge (or place installer in ${CACHE_MINIFORGE}/)" >&2
    exit 1
  fi
  echo "    downloading ${url}" >&2
  echo "    → ${dest}" >&2
  curl -fsSL -o "${dest}.partial" "${url}"
  mv "${dest}.partial" "${dest}"
  printf '%s\n' "${dest}"
}

install_miniforge() {
  local installer path t0 t1
  installer="$(detect_installer)"
  t0="$(now_s)"
  echo "==> Installing Miniforge to ${CONDA_PREFIX_DIR}"
  path="$(fetch_miniforge_installer "${installer}")"
  if [[ ! -f "${path}" ]]; then
    echo "ERROR: Miniforge installer not found: '${path}'" >&2
    exit 1
  fi
  bash "${path}" -b -p "${CONDA_PREFIX_DIR}"
  t1="$(now_s)"
  T_MINIFORGE="$((t1 - t0))"
  MINIFORGE_ACTION="installed"
  echo "==> Miniforge installed ($(fmt_elapsed "${T_MINIFORGE}"))"
}

# ---- optional: only seed cache ----
if [[ "${PREFETCH_ONLY}" -eq 1 ]]; then
  installer="$(detect_installer)"
  echo "==> Prefetch Miniforge into ${CACHE_MINIFORGE}"
  t0="$(now_s)"
  fetch_miniforge_installer "${installer}" >/dev/null
  t1="$(now_s)"
  echo "==> Prefetch done ($(fmt_elapsed "$((t1 - t0))"))"
  echo "    cache: ${CACHE_MINIFORGE}/${installer}"
  exit 0
fi

echo "==> Cache dir: ${CACHE_DIR}"
echo "    CONDA_PKGS_DIRS=${CONDA_PKGS_DIRS}"
[[ "${OFFLINE}" -eq 1 ]] && echo "    mode: OFFLINE (no network downloads)"

ensure_lo_dirs

if [[ ! -x "${CONDA_PREFIX_DIR}/bin/conda" ]]; then
  install_miniforge
else
  MINIFORGE_ACTION="existing"
  echo "==> Found existing Miniforge at ${CONDA_PREFIX_DIR}"
fi

# shellcheck disable=SC1091
source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh"

# Force envs into this Miniforge (do not use ~/envs from ~/.condarc)
export CONDA_ENVS_DIRS="${CONDA_PREFIX_DIR}/envs"
ENV_PREFIX="${CONDA_ENVS_DIRS}/${ENV_NAME}"
mkdir -p "${CONDA_ENVS_DIRS}"
echo "    CONDA_ENVS_DIRS=${CONDA_ENVS_DIRS}"
echo "    env prefix: ${ENV_PREFIX}"

if command -v mamba >/dev/null 2>&1; then
  CREATE=(mamba env create)
  UPDATE=(mamba env update)
  REMOVE=(mamba env remove)
else
  CREATE=(conda env create)
  UPDATE=(conda env update)
  REMOVE=(conda env remove)
fi

if [[ "${OFFLINE}" -eq 1 ]]; then
  CREATE+=(--offline)
  UPDATE+=(--offline)
fi

# Editable -e ./LO/lo_tools must resolve relative to DEPS_ROOT
cd "${DEPS_ROOT}"

t0="$(now_s)"
if [[ -d "${ENV_PREFIX}/conda-meta" ]]; then
  if [[ "${FORCE_RECREATE}" -eq 1 ]]; then
    echo "==> Removing existing env at ${ENV_PREFIX} (--force-recreate)"
    "${REMOVE[@]}" -p "${ENV_PREFIX}" -y
    echo "==> Creating env '${ENV_NAME}' at ${ENV_PREFIX}"
    "${CREATE[@]}" -p "${ENV_PREFIX}" -f "${YML}"
    ENV_ACTION="recreated"
  else
    echo "==> Env already exists at ${ENV_PREFIX} — updating from hindcast.yml"
    echo "    (use --force-recreate for a clean rebuild)"
    "${UPDATE[@]}" -p "${ENV_PREFIX}" -f "${YML}" --prune
    ENV_ACTION="updated"
  fi
else
  echo "==> Creating env '${ENV_NAME}' at ${ENV_PREFIX}"
  "${CREATE[@]}" -p "${ENV_PREFIX}" -f "${YML}"
  ENV_ACTION="created"
fi
t1="$(now_s)"
T_ENV="$((t1 - t0))"
echo "==> Env step done (${ENV_ACTION}, $(fmt_elapsed "${T_ENV}"))"

T_TOTAL="$(( $(now_s) - T_START ))"

echo
echo "==> Done."
echo "    timing:"
echo "      Miniforge : ${MINIFORGE_ACTION}  $(fmt_elapsed "${T_MINIFORGE}")"
echo "      hindcast  : ${ENV_ACTION}  $(fmt_elapsed "${T_ENV}")"
echo "      total     : $(fmt_elapsed "${T_TOTAL}")"
echo "    CONDA_BASE=${CONDA_BASE}"
echo "    HINDCAST_ENV_PREFIX=${ENV_PREFIX}"
echo "    CACHE_DIR=${CACHE_DIR}"
echo "    LO_DATA=${LO_DATA}"
echo "    LO_OUTPUT=${LO_OUTPUT}"
echo "    LO_ROMS=${LO_ROMS}"
echo "    CAWO_HINDCAST_BASE=${CAWO_HINDCAST_BASE}"
echo "    Activate with:"
echo "      source ${CONDA_BASE}/etc/profile.d/conda.sh"
echo "      conda activate ${ENV_PREFIX}"
echo "    Or from inacawo-iht:"
echo "      source \$HOME/inacawo-iht/setup_env.bash"
