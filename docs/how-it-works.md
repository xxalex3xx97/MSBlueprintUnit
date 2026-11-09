# How it works

MSBlueprintUnit is pure Lua on top of MSCore. It has no native code of its own and no C++ build step. Pak files only add the block's meshes, UI and registry data (see [building-paks.md](building-paks.md)).

## Modules

All scripts live in `mods/BlueprintUnit/Scripts/`.

| File | Role |
|---|---|
| `main.lua` | Entry point. Checks the MSCore version, wires the window and the build state machine. |
| `bpu_version.lua` | Version string. `scripts/release.ps1` refuses a release whose `-Version` differs. |
| `bpu_json.lua` | Parses the pasted blueprint JSON. |
| `bpu_plan.lua` | Sync planner. Compares the blueprint with the factory on the station and returns the plan: KEEP, PLACE, STALE (remove), and recipe changes, with the net cost. |
| `bpu_live.lua` | Live reads of the station: existing machines, inventories, container contents, player inventory. Reads only. |
| `bpu_build.lua` | Build state machine (below). Changes the factory. |
| `bpu_blocks.lua` | Station Build logic, pure Lua: diff of the blueprint blocks against the station, rotated bounds, overlap, classify (add, remove, skip with a note), net cost, shortfall, and the send sequence. |
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

## Station Build (optional)

Off unless the **Station Build** checkbox is ticked. Needs MSCore 0.8.0 or newer (`add_block`, `remove_block`, `pending`, `read_block_class`).

- **Plan** (`bpu_plan`, `bpu_blocks`): blocks of the JSON that are missing on the station are classified. Skipped with a note: class not in this game, not a station block, locked by research (read in Lua from `DMSWorld:GetResearchState()`), overlapping another block of the JSON. A live block that overlaps a block to add, and is not in the JSON, goes to a remove list (never the Blueprint Unit block). Overlap uses the block bounds from `read_block_class`: raw /65536, which is 4x the grid unit in x and y and 2x in height; the game keeps each box slightly under its size, so neighbouring blocks do not overlap.
- **Cost**: net per item = added blocks minus refunds of removed blocks. If the unit and the player together cannot pay, Build refuses with the missing items before anything is sent. Creative mode skips the refusal.
- **Send** (`bpu_build`, stage 18, once, never resent): `pending(reset)`, `remove_block` for each block in the way, `add_block` for each block, `pending(apply)`: one apply, so the game nets the costs. The commands go to the station (no AttachTargetID) with full class paths. Then it polls `read_station` until the added blocks exist and the removed ones are gone (10 s), and the factory build continues.
- **Refund redirect**: MSCore 0.8.1 starts with the redirect off. `bpu_build` switches it on right before a build (only if it was off) and off again on every end of the run (finish, fail, cancel, nothing to build); a tick safety net clears it if a run ends without doing so.
- **Notes** are plain sentences; technical detail goes to `bpu_trace.log` (dated lines, capped at 2 MB).

## Hidden container

The unit has a hidden container machine with 120 slots and a +1,000,000% stack size. It holds the refunds and the staged items.

## Chk_Restore (container contents)

Chk_Restore unchecked: the cost list (need, shortfall) leaves out the container contents that would be restored. Refunds are unchanged. Toggling refreshes the list at once from the last plan, no replan. Build restore is off.

## Registration and window

- The block and its research are shipped in the pak (`pakchunk100-BlueprintUnit_P`: registry + research). `main.lua` does not call `MSCore.blocks.register`.
- The window is a UMG widget from the window pak (`pakchunk102-BPUnitUI_P`). It is shown through the Widget Subsystem, like the other MSCore UI.
