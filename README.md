# inacawo-deps

Pinned dependencies for the InaCAWO hindcast workflow.

## Layout

```
$HOME/inacawo-deps/
  env                          # path SST (LO, conda, CAWO_HINDCAST_BASE, …)
  coawst.bash_env_intel.source_oneapi  # Intel/COAWST toolchain (COAWST_ENV)
  install_hindcast_env.bash   # wrapper: dirs + COAWST deps + Miniforge + hindcast env
  hindcast.yml
  LO/                         # LiveOcean code (pip editable lo_tools)
  miniforge3/                 # local Miniforge (gitignored; created by wrapper)

$HOME/apps/                   # APPS_BASE (outside the repo; created by wrapper)
  cawo_depends/intel_2021.5.1/
    build/{bin,include,lib}   # NetCDF-C/F, HDF5, MCT, jasper, … → LIBDEP=build/lib
    src/                      # sources + build scripts of the deps
    .inacawo_installed        # marker: tarball, sha256, install date

$HOME/inacawo-iht/preprocess/
  LO_user/                    # LO user config + forcing drivers
  get_era5/ get_glorys/ get_roms_icbc/ get_swan_bry/ wps_run/

/scratch/$USER/inacawo-iht/          # CAWO_HINDCAST_BASE
  cawo_input/                   # CAWO_INPUT
    LO_data/ LO_output/ LO_roms/
    roms_forcing/ era5/ mercator/ wps_run/ swan_bcs/ …
  cawo_hindcast_run/ cawo_output/ cawo_post/
```

## One-shot install (recommended)

On a new machine, after cloning this repo:

```bash
cd $HOME/inacawo-deps
bash install_hindcast_env.bash
```

The wrapper will:

1. Ensure user-relative LO dirs under `/scratch/$USER/inacawo-iht/cawo_input/` (`LO_data`, `LO_data/grids`, `LO_output`, `LO_roms`) and `LO_user` if `inacawo-iht` is already cloned (paths from `env`)
2. Extract the compiled **COAWST model deps** into `$HOME/apps/cawo_depends/intel_2021.5.1` (see below)
3. Install **Miniforge3** into `$HOME/inacawo-deps/miniforge3` if `conda` is not already there
4. Create (or update) the **`hindcast`** env from `hindcast.yml` (includes editable `./LO/lo_tools`)

Shared with iht: `CAWO_HINDCAST_BASE`, `CAWO_INPUT`, `LO` / `LO_USER` / `LO_DATA` / `LO_OUTPUT` / `LO_ROMS`, `CONDA_BASE`, `CONDA_ENVS_DIRS` / `HINDCAST_ENV_PREFIX`, `APPS_BASE`, `LIBDEP`, `COAWST_ENV` (defined here only — `inacawo-iht/env` sources this file and must not redefine them).

The `hindcast` env is always created at **`$CONDA_BASE/envs/hindcast`** (not `~/envs`), even if `~/.condarc` sets a different `envs_dirs`.

Options:

```bash
bash install_hindcast_env.bash --force-recreate      # delete + recreate hindcast
bash install_hindcast_env.bash --prefetch-miniforge  # download installer into cache only
bash install_hindcast_env.bash --offline             # no network; use local cache
bash install_hindcast_env.bash --cache-dir /path     # override cache root
bash install_hindcast_env.bash --only-coawst-deps    # model libs only (no conda)
bash install_hindcast_env.bash --skip-coawst-deps    # conda / LO only
bash install_hindcast_env.bash --force-coawst-deps   # remove + re-extract model libs
bash install_hindcast_env.bash --coawst-tarball PATH # override deps tarball
```

### COAWST model deps (NetCDF, HDF5, MCT, …)

Prebuilt with Intel oneAPI 2021.5.1 (NetCDF-C 4.6.1, NetCDF-Fortran 4.4.5,
HDF5 1.10.6, MCT 2.6.0, jasper, libpng, curl, szip, zlib, udunits, expat).
The wrapper extracts the shared tarball into `$APPS_BASE` (default `$HOME/apps`):

```
/scratch/cawohdcst_ft2/inacawo-iht/deps_tarballs/   # CAWO_DEPS_TARBALL_DIR (a+rX)
  apps.cawo_depends.mdclogin0.tar.gz              # 563 MB compressed
  SHA256SUMS
```

- Skipped if `$LIBDEP/libnetcdff.so` already exists (use `--force-coawst-deps` to redo).
- Verifies sha256 when `SHA256SUMS` sits next to the tarball.
- Rewrites the original build root baked into `nc-config`, `nf-config`, `*.la`,
  `*.pc`, `*.settings` to the new location, then checks `nf-config --prefix`
  / `nc-config --libdir` and the key libraries.
- Needs **~36 GiB** free in `$APPS_BASE` (almost all of it is netcdf-c test
  output under `src/`; `build/` itself is ~48 MB) and takes ~5 min.

Use them via `COAWST_ENV` (sets compilers, `NETCDF`, `NF_CONFIG`, `MCT_*`,
`LD_LIBRARY_PATH`, …):

```bash
source $HOME/inacawo-deps/env
source "${COAWST_ENV}"
nf-config --flibs
```

Maintainer: refresh the shared tarball (run as `cawohdcst_ft2`):

```bash
D=/scratch/cawohdcst_ft2/inacawo-iht/deps_tarballs
cp -p $HOME/apps/tars/apps.cawo_depends.mdclogin0.tar.gz $D/
(cd $D && sha256sum apps.cawo_depends.mdclogin0.tar.gz > SHA256SUMS)
chmod 755 $D && chmod 644 $D/*
```

### Timing

The wrapper prints elapsed time for **COAWST deps**, **Miniforge**, **hindcast env**, and **total**.

### Local / offline cache (flaky network)

Default cache root (shared on **scratch**, not `$HOME`):  
**`/scratch/cawohdcst_ft2/inacawo-deps-cache`**

```
$CACHE_DIR/
  miniforge/Miniforge3-Linux-x86_64.sh
  conda-pkgs/
  envs/hindcast/          # SHARED read-only hindcast env (--offline uses this)
```

Other users **cannot** read `$HOME/cawohdcst_ft2/...`. Always put shareable
installers / reference envs under this scratch cache and `chmod -R a+rX`.

**`--offline`** (recommended when network is flaky): no package downloads and
**no 4G copy**. Points `HINDCAST_ENV_PREFIX` at the shared scratch env and
writes `hindcast_env.prefix`. Each user’s own `$HOME/inacawo-deps/LO/lo_tools`
is used via `$LO` (shared env is read-only).

```bash
# Other users (no permission on ft2 $HOME):
bash install_hindcast_env.bash --offline
# → uses /scratch/cawohdcst_ft2/inacawo-deps-cache/envs/hindcast

# Optional private copy (slow; only if you need a writable env):
bash install_hindcast_env.bash --offline --from-clone \
  /scratch/cawohdcst_ft2/inacawo-deps-cache/envs/hindcast
```

Maintainer: refresh the shared reference env after updating hindcast:

```bash
rm -rf /scratch/cawohdcst_ft2/inacawo-deps-cache/envs/hindcast
conda create -p /scratch/cawohdcst_ft2/inacawo-deps-cache/envs/hindcast \
  --clone $HOME/opt/miniforge3/envs/hindcast -y
chmod -R a+rX /scratch/cawohdcst_ft2/inacawo-deps-cache
```

Requires `curl` for the first Miniforge download (unless the installer is already cached). `miniforge3/` under the repo is gitignored (do not commit it).

Then from the workflow repo:

```bash
source $HOME/inacawo-iht/setup_env.bash   # uses CONDA_BASE=inacawo-deps/miniforge3 when present
```

## Manual install (alternative)

If you already manage conda yourself:

```bash
cd $HOME/inacawo-deps
mamba env create -f hindcast.yml
# or: conda env create -f hindcast.yml
conda activate hindcast
```

Must run from this directory so `./LO/lo_tools` resolves.

Override `CONDA_BASE` before sourcing if your prefix is not under `inacawo-deps/miniforge3` or `$HOME/opt/miniforge3` (set in `inacawo-deps/env`).
