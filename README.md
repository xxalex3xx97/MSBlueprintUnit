# MSBlueprintUnit

Blueprint Unit for Main Sequence Demo. A station block that builds a factory from a blueprint JSON.

Unofficial fan mod. Game assets belong to the game's developer and publisher. The code is MIT, see `LICENSE`.

## What it is

A **Blueprint Unit** station block, cloned from the Command Module and researched under **Computation Science**. Paste a factory blueprint exported from the [ms-factory-blueprint site](https://xxalex3xx97.github.io/ms-factory-blueprint/), check the modification cost, and the unit builds that factory on your station.

## Requirements

- Main Sequence Demo (Steam).
- **MSCore 0.7.6 or newer**, installed with **MSCoreManager.exe**. Needs MSCore 0.7.6 for machine configs (splitters, refineries, enrichment, recipes): older MSCore truncated config bytes.
- **MSCore 0.8.0 or newer** only for the optional **Station Build** checkbox; **MSCore 0.8.1** so that deconstructing by hand refunds into your own inventory (older MSCore keeps the refund redirect always on).
- No other mod needed. Does not need MiningBenchMod or the Mining Unit.

## Install

Use **MSCoreManager.exe** from the [MSCore releases](https://github.com/xxalex3xx97/MSCore/releases/latest).

1. Close the game.
2. Run `MSCoreManager.exe` and click **Install/Repair MSCore** (if not installed yet).
3. Click **Add mod...** and enter `xxalex3xx97/MSBlueprintUnit`.
4. Start the game.

**Manual install (only if the manager cannot be used).** Install MSCore first.
1. Close the game. Copy `Mods\BlueprintUnit` from the zip into `<game>\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\`. Copy the `Paks` files into `<game>\Windows\MainSequence\Content\Paks\`.
2. In `Binaries\Win64\ue4ss\Mods\mods.txt` add the line `BlueprintUnit : 1`.
3. Start the game.

**Uninstall.** Remove the placed Blueprint Units first. In MSCoreManager, select the mod and click **Remove mod**. If you remove the mod while Blueprint Units are placed, those units become missing blocks.

## Usage

1. Research **Computation Science**.
2. Build a **Blueprint Unit** in the Designer.
3. Press **F** on the console to open the window.
4. **Import**: paste the blueprint JSON and import it.
5. Check the **Modification Cost** list.
6. **Build**.

**What Build does:**
- Places the factory on your station.
- Never rebuilds identical machines. It only changes recipes.
- Takes the items it needs from the unit's inventory first, then from your inventory.
- Refunds of what the build removes go into the unit inventory. The redirect is on only while the build runs (MSCore 0.8.1), so your own deconstruction is not affected.
- Leftover items stay with you.
- Items inside removed containers also refund into the unit.
- Container contents are restored after Build, on by default. The **Enable container item restoration** checkbox turns it off (`restore_off.txt` also disables it). With MSCore 0.7.6 the unit sorts, splits the exact amount and moves it; older MSCore is not supported.
- While a build or restore runs, the **Build** button reads **Abort** and cancels it. Closing the window cancels it too; items already moved stay where they are.

**Station Build (optional checkbox, off by default).** Tick **Station Build (place station blocks + factory)** before Build to also place the station blocks of the JSON (Station 1x1, docks, elevators, ...), then the factory. Needs MSCore 0.8.0 or newer (the box says so when it is older).
- A block of the JSON that is missing from your station is placed. A live block that stands in the way (and is not in the JSON) is removed first; the removed block is refunded and the new one charged as one net cost. The Blueprint Unit block itself is never removed.
- Blocks locked by research are skipped, with a note. If the unit and you together cannot pay for all blocks, Build refuses with the list of missing items and builds nothing.
- A splitter that already exists with different port settings is removed and placed again with the new settings.

**Blueprint Unit inventory:** 120 slots, +1,000,000% stack size. Existing 1000-slot or 300-slot units keep their size: place a new unit.

## How to use

### 1. Get the unit

1. Research **Computation Science**.
2. In the Designer, add a **Blueprint Unit** block to your station.
3. Use the unit's console and press **F**. The window opens.

### 2. Import a blueprint

1. Build or pick a factory on the [ms-factory-blueprint site](https://xxalex3xx97.github.io/ms-factory-blueprint/) and export the JSON.
2. In the window click **Import**. A box titled **Import blueprint** opens.
3. Click in the box, **Ctrl+V** to paste, then click **Import** (or **Cancel**).

Paste the whole text exported by the site. Do not edit it by hand. Shape of a file (from `mods/BlueprintUnit/tests/fixtures/`, trimmed):

```json
{"Version":2,"DisplayName":"Tele",
 "Blocks":[{"Class":"/Game/Blueprints/BuildingBlocks/BPO_Station_01.BPO_Station_01_C","GridLocation":{"X":0,"Y":0},"Height":0,"GridRotation":0}],
 "DefaultMachines":[{"Class":"BP_ConveyorBeltObject","DefaultName":"DAT_ConveyorBelt","Transform":{"GridLocation":{"X":1,"Y":1},"Height":0,"GridRotation":0}}]}
```

`Blocks` are station blocks (only used with **Station Build**). `DefaultMachines` are the machines of the factory.

### 3. Read the cost, then Build

The **Modification Cost** list (left) is the net item cost: what the build places and changes, minus what the removals refund. Kept machines cost nothing.

| Control | What it does |
|---|---|
| **Import** | Paste a blueprint and compare it with your station. |
| **Pin** / **Unpin** (on the cost list) | Pins the net cost to the game's pinned cost list. |
| **Enable container item restoration** | On by default. Put the contents of removed containers back after Build. |
| **Station Build (place station blocks + factory)** | Off by default. Also places the station blocks of the JSON. |
| **Build** | Builds. While it runs, the button reads **Abort**. |

Click **Build**. The unit takes items from its own inventory first, then yours. While it runs, **Abort** (or closing the window) cancels it; items already moved stay where they are.

### 4. Station Build

Tick **Station Build (place station blocks + factory)** before **Build** if the JSON has station blocks your station lacks (docks, elevators, Station 1x1 ...). Needs MSCore 0.8.0 or newer. Without it, a JSON block that is not on your station is refused.

### 5. Container restore off

Untick **Enable container item restoration**, or create an empty file:

```
<game>\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\BlueprintUnit\restore_off.txt
```

### Messages and what to do

| Message | What to do |
|---|---|
| `import first` | Import a blueprint before **Build**. |
| `bad JSON: ...` / `the text is cut off ... paste it again` | The paste is incomplete or edited. Export again and paste the whole text. |
| `These blocks are not on the station grid: ... Fix them in the blueprint or tick Station Build.` | Tick **Station Build**, or fix the blueprint. |
| `not enough items: Name xN, ...` | Put the listed items in the unit or your inventory, then **Build**. Nothing was built. |
| `items missing in unit and player: ...` | Same: add the items and **Build** again. |
| `station changed since import, import again` | The station changed after the import. Click **Import** and paste again. |
| `the unit inventory is full, empty it and Build again` | Free slots in the unit inventory (shown in the window), then **Build**. |
| `... does not fit the player inventory, empty your inventory and Build again` | Free slots in your inventory, then **Build**. |
| `Station Build needs MSCore 0.8.0 or newer.` | Update MSCore with MSCoreManager, or untick **Station Build**. |
| `These station blocks cannot be placed: ... The factory was not built.` | Remove those blocks from the blueprint. |
| `nothing to build` | The station already matches the blueprint. |
| `restore is off (restore_off.txt in Mods/BlueprintUnit)` | `restore_off.txt` exists. Delete it to restore container items. |

If a message ends with `Build again`, fix what it says and click **Build** again. Technical detail goes to `bpu_trace.log`.

## Co-op

Every player in a co-op session needs the mod installed.

## Known limits

- Station Build places only the blocks of the JSON and removes blocks in their way; other live blocks are left alone. Tested in game with a Station 1x1 replacing a Shipyard side; other classes and rotations are untested.
- Teleporter cannot be placed by Build.
- Single-player tested. Co-op may desync after the split step.
- Belts and machine contents are not restored.

## Credits

- Blueprint format and site: [ms-factory-blueprint](https://xxalex3xx97.github.io/ms-factory-blueprint/).
- Built on MSCore.
- Main Sequence Demo by its developer and publisher.

## Developer docs

- [How it works](docs/how-it-works.md)
- [Building the paks](docs/building-paks.md)
