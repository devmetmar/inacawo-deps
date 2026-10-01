#!/bin/bash
# Install Miniforge into inacawo-deps (if missing), create required LO dirs for
# the current user, then create/update the hindcast conda env.
#
# Paths come from env (SST): source $DEPS_ROOT/env
#
# Usage:
#   bash $HOME/inacawo-deps/install_hindcast_env.bash
#   bash install_hindcast_env.bash --force-recreate
#   bash install_hindcast_env.bash --offline              # use shared scratch env
#   bash install_hindcast_env.bash --offline --from-clone PATH  # optional private copy
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

# Shared on-disk cache on scratch (readable by teammates; NOT under $HOME)
CACHE_DIR="${CACHE_DIR:-/scratch/cawohdcst_ft2/inacawo-deps-cache}"
# Shared hindcast env (default for --offline; no per-user copy)
DEFAULT_SHARED_ENV="${DEFAULT_SHARED_ENV:-${CACHE_DIR}/envs/hindcast}"
# Back-compat alias used by older docs/flags
DEFAULT_CLONE_SRC="${DEFAULT_CLONE_SRC:-${DEFAULT_SHARED_ENV}}"
PREFIX_FILE="${DEPS_ROOT}/hindcast_env.prefix"

FORCE_RECREATE=0
OFFLINE=0
PREFETCH_ONLY=0
CLONE_SRC=""
SEED_PKGS_FROM=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --force-recreate         Remove and recreate a *private* local hindcast env
  --offline, --local       No channel downloads; use shared scratch env (default)
  --from-clone PATH        Optional: rsync-copy PATH into private local env
  --seed-pkgs-from PATH    Copy/rsync conda pkgs dir into cache (for offline yaml create)
  --cache-dir DIR          Cache root (default: ${CACHE_DIR})
  --prefetch-miniforge     Download Miniforge installer into cache, then exit
  -h, --help               Show this help

Cache layout (all under scratch — group-readable, not \$HOME):
  \$CACHE_DIR/miniforge/Miniforge3-*.sh
  \$CACHE_DIR/conda-pkgs/
  \$CACHE_DIR/envs/hindcast/     # SHARED env used by --offline (preferred)

Examples:
  # Online: private env under \$HOME/inacawo-deps/miniforge3/envs/hindcast
  bash $0

  # Offline / flaky network: point at shared scratch env (no 4G copy)
  bash $0 --offline

  # Optional private offline copy (slow; only if you need a writable env)
  bash $0 --offline --from-clone ${DEFAULT_SHARED_ENV}

  # Maintainer: publish/update the shared env (run as cache owner)
  #   conda create -p \$CACHE_DIR/envs/hindcast --clone \$HOME/opt/miniforge3/envs/hindcast -y
  #   chmod -R a+rX \$CACHE_DIR

  bash $0 --prefetch-miniforge
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-recreate) FORCE_RECREATE=1 ;;
    --offline|--local|--local-only) OFFLINE=1 ;;
    --from-clone)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --from-clone needs a path" >&2; exit 1; }
      CLONE_SRC="$1"
      ;;
    --seed-pkgs-from)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --seed-pkgs-from needs a path" >&2; exit 1; }
      SEED_PKGS_FROM="$1"
      ;;
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

# ---- optional: seed package cache ----
if [[ -n "${SEED_PKGS_FROM}" ]]; then
  if [[ ! -d "${SEED_PKGS_FROM}" ]]; then
    echo "ERROR: --seed-pkgs-from not a directory: ${SEED_PKGS_FROM}" >&2
    exit 1
  fi
  echo "==> Seeding conda pkgs cache from ${SEED_PKGS_FROM}"
  echo "    → ${CACHE_PKGS}"
  t0="$(now_s)"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --info=progress2 "${SEED_PKGS_FROM}/" "${CACHE_PKGS}/"
  else
    cp -a "${SEED_PKGS_FROM}/." "${CACHE_PKGS}/"
  fi
  t1="$(now_s)"
  echo "==> Seed done ($(fmt_elapsed "$((t1 - t0))"))"
fi

pkgs_count() {
  # Count real package archives (ignore urls.txt / cache dirs)
  find "${CACHE_PKGS}" -maxdepth 1 \( -name '*.conda' -o -name '*.tar.bz2' \) 2>/dev/null | wc -l
}

reinstall_lo_tools() {
  echo "==> Reinstalling editable lo_tools into ${ENV_PREFIX}"
  # shellcheck disable=SC1091
  source "${CONDA_PREFIX_DIR}/etc/profile.d/conda.sh"
  conda run -p "${ENV_PREFIX}" python -m pip install -e "${DEPS_ROOT}/LO/lo_tools"
}

write_prefix_file() {
  local prefix="$1"
  printf '%s\n' "${prefix}" > "${PREFIX_FILE}"
  echo "    wrote ${PREFIX_FILE}"
  echo "      → ${prefix}"
}

use_shared_env() {
  local src="${1:-${DEFAULT_SHARED_ENV}}"
  if [[ ! -d "${src}/conda-meta" ]]; then
    echo "ERROR: shared hindcast env not found: ${src}" >&2
    echo "       Maintainer must publish it under \$CACHE_DIR/envs/hindcast" >&2
    exit 1
  fi
  if [[ ! -r "${src}/conda-meta" ]]; then
    echo "ERROR: cannot read shared env (permissions): ${src}" >&2
    echo "       Ask maintainer to: chmod -R a+rX ${CACHE_DIR}" >&2
    exit 1
  fi
  echo "==> Using SHARED hindcast env (no copy)"
  echo "    ${src}"
  ENV_PREFIX="${src}"
  write_prefix_file "${ENV_PREFIX}"
  # Do not pip-install into shared (read-only for other users).
  # setup_env + \$LO make each user's lo_tools visible via editable finder.
}

create_env_from_yml() {
  echo "==> Creating env '${ENV_NAME}' at ${ENV_PREFIX} from hindcast.yml"
  "${CREATE[@]}" -p "${ENV_PREFIX}" -f "${YML}"
  write_prefix_file "${ENV_PREFIX}"
}

# Rewrite absolute conda prefix in text files after a filesystem copy.
# (conda create --clone --offline still tries to fetch package archives.)
rewrite_conda_prefix() {
  local old_prefix="$1"
  local new_prefix="$2"
  python3 - "${old_prefix}" "${new_prefix}" <<'PY'
import os, sys
old, new = sys.argv[1], sys.argv[2]
old_b = old.encode()
n_files = 0
for root, _dirs, files in os.walk(new):
    for name in files:
        path = os.path.join(root, name)
        try:
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                data = f.read()
            if b"\0" in data or old_b not in data:
                continue
            text = data.decode("utf-8", errors="surrogateescape")
            updated = text.replace(old, new)
            if updated == text:
                continue
            with open(path, "wb") as f:
                f.write(updated.encode("utf-8", errors="surrogateescape"))
            n_files += 1
        except OSError:
            pass
print(f"    rewrote prefix in {n_files} text files")
print(f"    {old} → {new}")
PY
}

create_env_from_clone() {
  local src="$1"
  if [[ ! -d "${src}/conda-meta" ]]; then
    echo "ERROR: clone source is not a conda env: ${src}" >&2
    exit 1
  fi
  if [[ -e "${ENV_PREFIX}" ]]; then
    echo "==> Removing existing target before copy: ${ENV_PREFIX}"
    rm -rf "${ENV_PREFIX}"
  fi
  mkdir -p "$(dirname "${ENV_PREFIX}")"
  echo "==> Copying env to PRIVATE local prefix (slow; optional)"
  echo "    ${src}"
  echo "    → ${ENV_PREFIX}"
  t_copy="$(now_s)"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --human-readable --info=progress2,stats2 "${src}/" "${ENV_PREFIX}/"
  else
    echo "    (rsync missing — cp -av; very chatty)"
    mkdir -p "${ENV_PREFIX}"
    cp -av "${src}/." "${ENV_PREFIX}/"
  fi
  echo "    copy done ($(fmt_elapsed "$(( $(now_s) - t_copy ))"))"
  rewrite_conda_prefix "${src}" "${ENV_PREFIX}"
  reinstall_lo_tools
  write_prefix_file "${ENV_PREFIX}"
}

# Editable -e ./LO/lo_tools must resolve relative to DEPS_ROOT
cd "${DEPS_ROOT}"

# Local private prefix (online / --from-clone). Offline default uses shared instead.
LOCAL_ENV_PREFIX="${CONDA_PREFIX_DIR}/envs/${ENV_NAME}"
ENV_PREFIX="${LOCAL_ENV_PREFIX}"

t0="$(now_s)"
ENV_DONE=0

# --offline without --from-clone → use shared env (fast path)
if [[ "${OFFLINE}" -eq 1 && -z "${CLONE_SRC}" ]]; then
  use_shared_env "${DEFAULT_SHARED_ENV}"
  ENV_ACTION="shared"
  ENV_DONE=1
  t1="$(now_s)"
  T_ENV="$((t1 - t0))"
  echo "==> Env step done (${ENV_ACTION}, $(fmt_elapsed "${T_ENV}"))"
fi

if [[ "${ENV_DONE}" -ne 1 && -d "${ENV_PREFIX}/conda-meta" ]]; then
  if [[ "${FORCE_RECREATE}" -eq 1 ]]; then
    echo "==> Removing existing env at ${ENV_PREFIX} (--force-recreate)"
    "${REMOVE[@]}" -p "${ENV_PREFIX}" -y || rm -rf "${ENV_PREFIX}"
  else
    if [[ -n "${CLONE_SRC}" ]]; then
      echo "==> Env already exists at ${ENV_PREFIX} — skip clone (use --force-recreate to replace)"
      write_prefix_file "${ENV_PREFIX}"
      ENV_ACTION="exists"
    else
      echo "==> Env already exists at ${ENV_PREFIX} — updating from hindcast.yml"
      echo "    (use --force-recreate for a clean rebuild)"
      "${UPDATE[@]}" -p "${ENV_PREFIX}" -f "${YML}" --prune
      write_prefix_file "${ENV_PREFIX}"
      ENV_ACTION="updated"
    fi
    t1="$(now_s)"
    T_ENV="$((t1 - t0))"
    echo "==> Env step done (${ENV_ACTION}, $(fmt_elapsed "${T_ENV}"))"
    ENV_DONE=1
  fi
fi

if [[ "${ENV_DONE}" -ne 1 ]]; then
  ENV_PREFIX="${LOCAL_ENV_PREFIX}"
  mkdir -p "${CONDA_ENVS_DIRS}"
  if [[ -n "${CLONE_SRC}" ]]; then
    create_env_from_clone "${CLONE_SRC}"
    ENV_ACTION="cloned"
  elif [[ "${OFFLINE}" -eq 1 ]]; then
    n_pkgs="$(pkgs_count)"
    if [[ "${n_pkgs}" -lt 10 ]]; then
      echo "ERROR: --offline with --from-clone needed a source, or seed pkgs for yaml create." >&2
      echo "       Shared env missing/unreadable and pkgs cache has ${n_pkgs} archives." >&2
      echo "       Fix options:" >&2
      echo "         1) bash $0 --offline                          # use shared env" >&2
      echo "         2) bash $0 --offline --from-clone ${DEFAULT_SHARED_ENV}" >&2
      echo "         3) bash $0 --seed-pkgs-from /path/to/pkgs     # then --offline --from-clone skipped + yaml" >&2
      exit 1
    fi
    create_env_from_yml
    ENV_ACTION="created"
  else
    create_env_from_yml
    ENV_ACTION="created"
  fi
  t1="$(now_s)"
  T_ENV="$((t1 - t0))"
  echo "==> Env step done (${ENV_ACTION}, $(fmt_elapsed "${T_ENV}"))"
fi

T_TOTAL="$(( $(now_s) - T_START ))"

echo
echo "==> Done."
echo "    timing:"
echo "      Miniforge : ${MINIFORGE_ACTION}  $(fmt_elapsed "${T_MINIFORGE}")"
echo "      hindcast  : ${ENV_ACTION}  $(fmt_elapsed "${T_ENV}")"
echo "      total     : $(fmt_elapsed "${T_TOTAL}")"
echo "    CONDA_BASE=${CONDA_BASE}"
echo "    HINDCAST_ENV_PREFIX=${ENV_PREFIX}"
echo "    HINDCAST_SHARED_ENV=${DEFAULT_SHARED_ENV}"
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
