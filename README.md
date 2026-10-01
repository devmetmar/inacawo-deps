# inacawo-deps

Pinned dependencies for the InaCAWO hindcast workflow.

## Layout

```
$HOME/inacawo-deps/
  env                          # path SST (LO, conda, CAWO_HINDCAST_BASE, …)
  coawst.bash_env_intel.source_oneapi  # Intel/COAWST toolchain (COAWST_ENV)
  install_hindcast_env.bash   # wrapper: dirs + Miniforge + hindcast env
  hindcast.yml
  LO/                         # LiveOcean code (pip editable lo_tools)
  miniforge3/                 # local Miniforge (gitignored; created by wrapper)
  apps/                       # compiled deps (NetCDF, MCT, …) → LIBDEP

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
2. Install **Miniforge3** into `$HOME/inacawo-deps/miniforge3` if `conda` is not already there
3. Create (or update) the **`hindcast`** env from `hindcast.yml` (includes editable `./LO/lo_tools`)

Shared with iht: `CAWO_HINDCAST_BASE`, `CAWO_INPUT`, `LO` / `LO_USER` / `LO_DATA` / `LO_OUTPUT` / `LO_ROMS`, `CONDA_BASE`, `LIBDEP`, `COAWST_ENV` (defined here only — `inacawo-iht/env` sources this file and must not redefine them).

Options:

```bash
bash install_hindcast_env.bash --force-recreate      # delete + recreate hindcast
bash install_hindcast_env.bash --prefetch-miniforge  # download installer into cache only
bash install_hindcast_env.bash --offline             # no network; use local cache
bash install_hindcast_env.bash --cache-dir /path     # override cache root
```

### Timing

The wrapper prints elapsed time for **Miniforge**, **hindcast env**, and **total**.

### Local / offline cache (flaky network)

Default cache root: **`/scratch/cawohdcst_ft2/inacawo-deps-cache`**

```
$CACHE_DIR/
  miniforge/Miniforge3-Linux-x86_64.sh   # installer (auto-downloaded, or copy by hand)
  conda-pkgs/                            # shared CONDA_PKGS_DIRS
```

- Online runs download the Miniforge installer into the cache (retries reuse it) and store conda packages under `conda-pkgs/` so later installs (or other users pointing at the same cache) hit disk first.
- If the network is down after a successful seed:

```bash
bash install_hindcast_env.bash --offline
```

- Manual seed of the installer (e.g. scp from another host):

```bash
mkdir -p /scratch/cawohdcst_ft2/inacawo-deps-cache/miniforge
# place Miniforge3-Linux-x86_64.sh there, then:
bash install_hindcast_env.bash --offline
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
