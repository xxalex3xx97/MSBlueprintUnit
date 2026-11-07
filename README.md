# MSBlueprintUnit

Blueprint Unit for Main Sequence Demo. A station block that builds a factory from a blueprint JSON.

Unofficial fan mod. Game assets belong to the game's developer and publisher. The code is MIT, see `LICENSE`.

## What it is

A **Blueprint Unit** station block, cloned from the Command Module and researched under **Computation Science**. Paste a factory blueprint exported from the [ms-factory-blueprint site](https://xxalex3xx97.github.io/ms-factory-blueprint/), check the modification cost, and the unit builds that factory on your station.

## Requirements

- Main Sequence Demo (Steam).
- **MSCore 0.7.2 or newer**, installed with **MSCoreManager.exe**.
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
- Stages the items it needs from the unit's own inventory first, then from your inventory.
- Refunds go into the unit inventory.
- Leftover items stay with you.

**Blueprint Unit inventory:** 120 slots, +10,000% stack size.

## Co-op

Every player in a co-op session needs the mod installed.

## Known limits

- Station blocks cannot be imported yet. Only factory blueprints.
- Teleporter cannot be placed by Build.

## Credits

- Blueprint format and site: [ms-factory-blueprint](https://xxalex3xx97.github.io/ms-factory-blueprint/).
- Built on MSCore.
- Main Sequence Demo by its developer and publisher.

## Developer docs

- [How it works](docs/how-it-works.md)
- [Building the paks](docs/building-paks.md)
