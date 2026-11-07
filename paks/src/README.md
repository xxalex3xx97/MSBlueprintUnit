# Blueprint Unit pak (M2)
Cooks the Blueprint Unit block (BPO_BlueprintUnit / BP_BlueprintUnit) plus its table mesh and registry patch for Main Sequence. Also clones STB_BPUnitPromp ("to Use Blueprint"), renames the hologram mesh to SM_BPUnitBlueprintHolo_01 and patches its transform (HOLO_SCALE / HOLO_Z consts in clone.js).
Build order: `build_mesh.ps1` (pakchunk97 mesh), then `build_pak.ps1` (pakchunk100 blocks, runs clone.js + patch_registry.py 3 B + patch_research.py).
Outputs in `out\`: pakchunk97-BPUnitMesh_P.{pak,ucas,utoc} and pakchunk100-BlueprintUnit_P.{pak,ucas,utoc}.
Blender: `mk_table.py` is a bpy script that generates `art\SM2_BPUnitTbl.fbx` (run it inside Blender; Blender exe path not recorded here).
Not installed by the build: copy the pak files into the game's Paks folder yourself.
Co-op: every player needs the same pak. Chunk 97 is also used by the dev MSTestCube pak: never install both.
Tools: MS_MODS_ROOT (default F:\MSDemoMods) for legacy/ source and tools\retoc.

## S1 hidden container default machine (build variants)
- `build_pak.ps1 -Container none|vanilla|clone [-Pos X,Y]` (default none, 8,8). Output `out\<variant>\pakchunk100-BlueprintUnit_P.{pak,ucas,utoc}`; default pos also copied to `out\`. Other pos -> `out\<variant>_<X>_<Y>\` (not copied to `out\`).
- `-Pos X,Y` = machine position (int32 X, Y, block-relative machine units, scale not verified). Element = count | `80 09 0c` class | `80 07 06` transform | X | Y (22 bytes). Env `BPU_MX`/`BPU_MY` read by patch_bpo_machine.py.
  - none: 5 packages, no container.
  - vanilla: 5 packages, container = vanilla `BP_ContainerObject_2` (32 slots, bonus 10). No Machines clone. Try this first.
  - clone: 7 packages (+ `Machines/BP_BPUnitStoreObj_01` sim, + `Machines/BP_BPUnitSto_2` actor), container = clone sim (120 slots, bonus 200).
  - **Install pakchunk97 (BPUnitMesh, has `SM2_BPUnitHidden00`) AND pakchunk100 together** for the clone variant. The actor's mesh is the tiny collision-free hidden mesh from pak97; without it the actor will not load.
- Container = DefaultMachines entry. It is NOT the connector array: vanilla uexp 374 is the CONNECTOR array (`BPO_LargeConnector_C`, count 1, end 404), left untouched.
  DefaultMachines is a separate property, unversioned-header index 24, absent in BPO_CommandModule. `patch_bpo_machine.py <DIR> <CLASS PKG> <CLASS NAME>`:
  header uexp 116-117 `07 02` -> `02 02 04 02` (+2 bytes, idx 24 added), 14-byte value `01 00 00 00 | 80 09 0c | class ref | 80 07 07` inserted before idx 29 value (`ff ff ff ff`).
  Export 1 SerialSize +16. Connector array moves 374 -> 376 (its end 404 -> 406) after the header growth; verify() checks it there.
  Machine cell (0,0), no payload. Real placement later: `80 07 06` + X,Y int32, machine coords ~8x finer than block cells.
- Names/imports/preload: +2 names, +2 imports (package + BlueprintGeneratedClass), +1 CreateBefore preload entry (export 1, same as connector).
- `python -I patch_bpo_machine.py --walk <base>` prints the CONNECTOR walk only.
- clone.js Job D (gated on BPU_CONTAINER=1): sim BP_ContainerObject_2 -> BP_BPUnitStoreObj_01, InventorySize @120 32->120, bonus @124 10->200. Actor BP_Container_2 -> `Machines/BP_BPUnitSto_2` (copy, invisible: mesh SM2_LargeContainer -> SM2_BPUnitHidden00).
  - Sim's actor import is FName base `/Game/Blueprints/Machines/BP_Container` with FName number 3 (the `_2` suffix is the number, not a dangling name). Job D renames the base to `BP_BPUnitSto` (same length), so number 3 resolves to `/Game/Blueprints/Machines/BP_BPUnitSto_2`. Class `BP_Container_2_C` -> `BP_BPUnitSto_2_C`.
  - Actor base rename skips `WBP_Container` (W before) and `BP_ContainerObject` (Object after). Actor header FString `/Game/Blueprints/Machines/BP_Container_2` -> `..._BP_BPUnitSto_2`.
  - Parent `BP_ContainerObject` stays vanilla. Sim leftover scan: no `BP_Container\0`, no `BP_Container_2`.
- Previous crash cause: container appended to the CONNECTOR array (debugger finding). Not yet tested in game.

## Window fix (vanilla suppress)
- clone.js Job E: BP_BlueprintUnit.uasset import WBP_StationInventory -> WBP_BPUnitNoWindow00 (same length, ascii+utf16; 3 hits: package path, WBP_StationInventory_C, Default__). Same trick as Mining Unit WBP_Workbench -> WBP_MiningUnt. Lua also closes any live WBP_StationInventory_C 100 ms after open (main.lua closeVanilla).
