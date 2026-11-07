# tooling/probes (DEV ONLY, never shipped)

## p0_reads.lua: P0 read gate (UE4SS Lua, read-only)

Checks that the live reads the C++ probe did (mb_bpprobe.hpp) work from UE4SS Lua:
station Blueprint Blocks/Machines, Buildable ItemCost, player/container inventory, MSCore surface, Recipe names, timing.
Sends no command and writes no game object.

### Install (temp, dev only)
1. Create `F:\SteamLibrary\steamapps\common\Main Sequence Demo\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\BlueprintUnitP0\Scripts\`
   (same layout as `...\Mods\BlueprintUnitUI\`).
2. Copy `F:\MSBlueprintUnit\tooling\probes\p0_reads.lua` to `...\Mods\BlueprintUnitP0\Scripts\main.lua`.
3. Create an empty file `...\Mods\BlueprintUnitP0\enabled.txt` (next to `Scripts`).
4. Start the game, load a save with a station that has machines (a Blueprint Unit placed too if possible), get into the world.
5. Press F6, wait about 1 s.
6. Send `...\Mods\BlueprintUnitP0\Scripts\P0Result.txt` (the `P0 ` lines are also in UE4SS.log).
7. Delete the whole `...\Mods\BlueprintUnitP0\` folder afterwards.

### Notes
- Needs MSCore installed (R4 loads `Mods\MSCore\Scripts\mscore.lua`); missing MSCore only fails R4.
- Never copy this into the release or into `F:\MSDemoMods-public`.
- Syntax check: `F:\MSDemoMods-public\tests\out\luac.exe -p F:\MSBlueprintUnit\tooling\probes\p0_reads.lua`
