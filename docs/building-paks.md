# Building the paks

The block's meshes, UI and registry data ship as IoStore paks. Build steps are in `paks/src/` and `ue/`. The full pak rules (naming, retoc, cloning, research patches) are in the MSCore doc [patching-paks.md](https://github.com/xxalex3xx97/MSCore/blob/main/docs/mod-authors/patching-paks.md). Read that before you change a pak.

## Chunks

| Chunk | Pak | Holds |
|---|---|---|
| 97 | `pakchunk97-BPUnitMesh_P` | Blueprint Unit table mesh and hidden mesh |
| 100 | `pakchunk100-BlueprintUnit_P` | Blueprint Unit block, registry and research |
| 102 | `pakchunk102-BPUnitUI_P` | Blueprint Unit window |

A pak is three files with one base name: `.pak`, `.utoc`, `.ucas`. All three go together. A higher chunk number wins when two paks hold the same path. Do not reuse a chunk number that another mod ships.

Blocks register at runtime with `MSCore.blocks.register`. The old one-registry rule (a single `DAT_BuildingBlockRegistry` that every mod must merge into) no longer applies to this mod.

## Steps

1. Read `paks/src/README.md` (mesh and pak source steps), when it exists.
2. Run the driver: `powershell -File scripts\build_all.ps1`. It runs each step that exists and lists what is missing. It exits 1 if anything is missing or fails.
3. Output goes to `paks/prebuilt/`, the folder `scripts/release.ps1` reads from.
4. Check with `retoc verify <file>.utoc`. Test the real game load: `verify` checks only the container.

## Requirements

- `retoc.exe` in `tools\retoc\` or on PATH (MIT, fetched separately, not in the repo).
- The private UE 5.7 project in `ue\`, and `UE_ROOT` set to the UE install folder (cook step).
- `MS_MODS_ROOT` is set to this repo root by `build_all.ps1` when unset.
- Do not point any build step at the shared RE-UE4SS mirror used by the dev probe.

## Release

`powershell -File scripts\release.ps1 -Version <x.y.z> -DryRun` builds the zip into `build\release` and checks its content against the expected list. Without `-DryRun` it builds the same zip. Neither mode publishes anything.
