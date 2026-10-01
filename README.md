# inacawo-deps

Pinned dependencies for the InaCAWO hindcast workflow.

## Layout

```
$HOME/inacawo-deps/
  hindcast.yml
  LO/                                 # LiveOcean code (pip editable lo_tools)

$HOME/inacawo-iht/preprocess/
  LO_user/                            # LO user config + forcing drivers
  get_era5/ get_glorys/ get_roms_icbc/ get_swan_bry/ wps_run/

/scratch/$USER/LO_data/
/scratch/$USER/LO_output/
```

LO is a **preprocess** dependency: installed from here, configured and run via `inacawo-iht/preprocess/`.

## Create the `hindcast` conda env

```bash
cd $HOME/inacawo-deps
mamba env create -f hindcast.yml
conda activate hindcast
```

Must run from this directory so `./LO/lo_tools` resolves.
