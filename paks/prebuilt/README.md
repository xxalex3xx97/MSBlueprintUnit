# Prebuilt paks

Shipped paks for Blueprint Unit. Built from `paks/src/` and `ue/`.

- `pakchunk97-BPUnitMesh_P` : hidden collision-free machine mesh (SM2_BPUnitHidden00) + table/holo meshes.
- `pakchunk100-BlueprintUnit_P` : BPO_BlueprintUnit, BP_BlueprintUnit, STB_BPUnitPromp, Machines/BP_BPUnitStoreObj_01, Machines/BP_BPUnitSto_2 (container at block centre, clone_0_0 variant), plus DAT_BuildingBlockRegistry and RSC_ComputationScience. Blueprint Unit inventory: 120 slots, +1,000,000% stack size.
- `pakchunk102-BPUnitUI_P` : /Game/BlueprintUnitUI window (WBP_BlueprintUnit), built headless from `ue/scripts`. Has the **Station Build** checkbox (off by default) and the **Enable container item restoration** checkbox (checked by default).

## Notes

pak100 contains `DAT_BuildingBlockRegistry` and `RSC_ComputationScience` and ships as is in the release.

## Integrity

`SHA256SUMS.txt` lists the 9 files. Verify with `sha256sum -c SHA256SUMS.txt` from this folder.

Not installed by anything in this repo: copy the pak triples into the game's Paks folder yourself. Co-op: every player needs the same set.
