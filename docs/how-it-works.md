# How it works

MSBlueprintUnit is pure Lua on top of MSCore. It has no native code of its own and no C++ build step. Pak files only add the block's meshes, UI and registry data (see [building-paks.md](building-paks.md)).

## Modules

All scripts live in `mods/BlueprintUnit/Scripts/`.

| File | Role |
|---|---|
| `main.lua` | Entry point. Registers the block with `MSCore.blocks`, wires the window and the build state machine. |
| `bpu_version.lua` | Version string. `scripts/release.ps1` refuses a release whose `-Version` differs. |
| `bpu_json.lua` | Parses the pasted blueprint JSON. |
| `bpu_plan.lua` | Sync planner. Compares the blueprint with the factory on the station and returns the plan: KEEP, PLACE, STALE (remove), and recipe changes, with the net cost. |
| `bpu_live.lua` | Live reads of the station: existing machines, inventories, container contents, player inventory. Reads only. |
| `bpu_build.lua` | Build state machine (below). Changes the factory. |
| `bpu_window.lua` | The window: Import, Modification Cost list, Build button. |

## Plan

`bpu_plan` returns a plan with these parts:
- **KEEP**: a machine that already matches the blueprint. Left alone, never rebuilt.
- **PLACE**: a machine in the blueprint with no match on the station.
- **STALE**: a station machine that is not in the blueprint. Removed.
- **Recipe changes**: a kept machine whose recipe differs. Only the recipe is set.

The net cost is the item cost of PLACE and recipe changes, minus the refunds from STALE removals.

## Build

`bpu_build` is a state machine with these steps:

1. **Removals**: remove STALE machines.
2. **Refund move-out**: move the refunded items into the unit's container.
3. **Staging**: fill the build items by quick-move (`InventoryInput`), first from the unit's container, then from the player inventory.
4. **Placement**: place each PLACE machine through `MSCore.factory_native`, then set recipes.
5. **Verify**: re-read the station with `bpu_live` and compare with the plan.

Leftover items stay with the player.

## Hidden container

The unit has a hidden container machine with 120 slots and a +10,000% stack size. It holds the refunds and the staged items.

## Registration and window

- The block is registered with `MSCore.blocks.register` in `main.lua`.
- The window is a UMG widget from the window pak (`pakchunk102-BPUnitUI_P`). It is shown through the Widget Subsystem, like the other MSCore UI.
