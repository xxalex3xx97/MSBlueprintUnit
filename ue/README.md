# ue/ : Blueprint Unit window tooling (UE 5.7)

`ue/scripts/` holds the headless scripts that author the Blueprint Unit window `/Game/BlueprintUnitUI/WBP_BlueprintUnit` and cook/pack it into pakchunk102-BPUnitUI_P.

- `mk_bpunit_wbp.py` : builds the window WBP via the UE Python API (uses `uew.py` helpers).
- `chk_bpunit_wbp.py` : checks the built WBP.
- `bpunit_refscan.py` : scans referenced assets so the pak only references `/Game/BlueprintUnitUI/*` (own prefix).
- `bpunit_cook.ps1` : cook commandlet for the UI project (`-EngineRoot`, default `$env:UE_ROOT` else `F:\UE_5.7`).
- `bpunit_pack.ps1` : runs retoc on the cooked output (`MS_MODS_ROOT`, default `F:\MSDemoMods`).

## Regenerating the window

Needs the PRIVATE UE 5.7 project `MiningUnitUI` (not in this repo). Donor widgets from WBP_MiningUnit (`/Game/MiningUnitUI`) are needed for 'Is Variable'. The project's `.uproject` and `Content/` are NOT copied here.

## Shipped paks

The shipped paks are prebuilt: see `paks/prebuilt/` (with SHA256SUMS). You do not need UE to install or test them. Regenerating is only needed when the window changes.
