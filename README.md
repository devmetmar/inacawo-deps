# inacawo-deps

Pinned dependencies for the InaCAWO hindcast workflow.

## Layout

```
$HOME/inacawo-deps/
  install_hindcast_env.bash   # wrapper: Miniforge + hindcast env
  hindcast.yml
  LO/                         # LiveOcean code (pip editable lo_tools)
  miniforge3/                 # local Miniforge (gitignored; created by wrapper)

$HOME/inacawo-iht/preprocess/
  LO_user/                    # LO user config + forcing drivers
  get_era5/ get_glorys/ get_roms_icbc/ get_swan_bry/ wps_run/

/scratch/$USER/LO_data/
/scratch/$USER/LO_output/
```

## One-shot install (recommended)

On a new machine, after cloning this repo:

```bash
cd $HOME/inacawo-deps
bash install_hindcast_env.bash
```

The wrapper will:

1. Install **Miniforge3** into `$HOME/inacawo-deps/miniforge3` if `conda` is not already there
2. Create (or update) the **`hindcast`** env from `hindcast.yml` (includes editable `./LO/lo_tools`)

Options:

```bash
bash install_hindcast_env.bash --force-recreate   # delete + recreate hindcast
```

Requires `curl` for the Miniforge download. `miniforge3/` is gitignored (do not commit it).

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

Point `CONDA_BASE` in `$HOME/inacawo-iht/env` at your prefix if it is not under `inacawo-deps/miniforge3` or `$HOME/opt/miniforge3`.
