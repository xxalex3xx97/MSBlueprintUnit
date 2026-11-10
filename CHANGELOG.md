# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] - 2026-11-10

Dock names need **MSCore 0.8.3 or newer**. Without it everything else works and the names are skipped with a message.

### Added
- **Dock names.** A blueprint JSON can name docks, industrial docks and shipyard cores (an optional `Name` on the block, written by the Factory Blueprint site). Check shows "dock names N". Build renames the docks that have a different name, for docks already on the station and for docks Station Build places in the same run.
- The status line says how many docks were renamed, and why some were not (for example "needs MSCore 0.8.3", "dock not found"). A dock is never renamed on a guess: no match or more than one match means it is skipped.
- A run that only renames docks (nothing else to build) now sends the names and finishes, instead of stopping at "nothing to build".

### Fixed
- Build no longer aborts in the middle of a Station Build run when a time value in a log line has decimals.

### Notes
- Tested in game (2026-11-10): docks on a real station renamed, including a dock placed by Station Build in the same run.
## [0.2.1] - 2026-11-09

Requires **MSCore 0.7.6 or newer**.

### Fixed
- Underground belts pair per floor (machine height): stacked floors no longer fail with "underground too long".
- Random Lua errors and crashes when importing large designs: the timers now run on the game thread.

### Changed
- **Enable container item restoration** unchecked: the cost list leaves out the container item costs, and toggling the box refreshes the cost list at once (no replan).

## [0.2.0] - 2026-11-08

Requires **MSCore 0.7.6 or newer** (the split native). Needs MSCore 0.7.6 for machine configs (splitters, refineries, enrichment, recipes): older MSCore truncated config bytes. Place a NEW unit for the bigger inventory: existing 1000-slot and 300-slot units keep their size. Station Build needs **MSCore 0.8.0 or newer**; the hand-deconstruction refund fix needs **MSCore 0.8.1**.

### Added
- **Station Build (place station blocks + factory)** checkbox (`Chk_StationBuild`, default unchecked). Ticked: the JSON's station blocks are placed first (one add sequence through MSCore), then the factory as before.
- Block rules: a class not in this game, a non-station block, a block whose research state is unknown, and a cell already occupied or overlapping another block of the file are skipped with a note. Locked (not researched) classes are listed as locked.
- Research state is read in Lua (`DMSWorld:GetResearchState():IsBlockUnlocked`); when it cannot be read the block is skipped, and one note says Station Build placed nothing when that holds for every class.
- Block costs are added to the cost list. If the unit and player together lack items for all blocks, Build is refused with the shortfall list and nothing is sent. Creative mode skips that refusal.
- Summary adds `blocks N` when the checkbox is ticked.
- A live block that stands in the way of a missing block of the file (and is not in the file itself) is **removed** first, then the block is placed, in one apply (reset, remove, add, apply). The unit block itself is never removed. The refund of the removed block is netted against the new block cost. Summary adds `removed M`.
- Notes are plain sentences ("Removed the Shipyard side that was in the way of a Station 1x1."), technical detail goes to `bpu_trace.log`, whose lines now carry the date.
- A splitter that already exists with different port settings is removed and placed again with the new config ("N splitters replaced").
- Ticked on an older MSCore: the hint under the box and the status line read "Station Build needs MSCore 0.8.0 or newer"; Import and Build stop.
- Trace (`bpu_trace.log`): every add, the poll of the station blocks, the research-state read per class.
- The refund redirect (MSCore) is switched on only while a Blueprint Unit build runs and off again afterwards, so deconstructing by hand refunds into your own inventory. Needs MSCore 0.8.1 for this (older MSCore keeps the redirect always on).

### Changed
- Window: **Enable container item restoration** checkbox (`Chk_Restore`, checked by default) with a hint line (`Txt_Restore`, `Txt_RestoreHint`). Unchecked = Build does no container restoration.
- Restore sorts the unit inventory first, then splits the exact missing amount into a free unit slot and moves it with one TRANSFER (needs the MSCore 0.7.6 split native; older MSCore keeps the whole-stack rounding). The split step edits the inventory locally (not a game command; in co-op it may desync until the next refresh).
- `Mods\BlueprintUnit\restore_off.txt` also disables container restore. `restore_on.txt` is no longer needed.
- Rounding (whole unit stacks, a smaller remainder left out with a note) is kept in code for tests only. MSCore 0.7.6 is required, so the normal route is sort, split the exact missing amount, then TRANSFER.
- A container's stack room is respected: a partial move leaves the rest in the unit, and a full container is noted ("container id N full").
- A refused send is retried on the next tick (up to 5 times), then skipped and counted in the note ("N command(s) skipped (refused)"). The restore never aborts for it.
- Restore sends up to 1000 commands per tick. It stops only when nothing changes in the restored items for 8 s after the last send (no fixed wait).
- Progress line while building and restoring: "restoring [#####-----] 50%  (1,234 of 2,468 commands)" and "sending commands: n of m (x%)".
- Build button: while a build or restore runs it reads **Abort** and cancels the run. Closing the window also cancels it.
- Notes panel hides the "skipped (block-built ...)" and "ConfigHex ignored for paired underground ..." lines. They stay in `bpu_trace.log`.
- Notes: "plan reduced: unit has X of Y for Item (short Z)" when the unit lacks an item; "items on belts and in machines are not restored" line after restore.
- The unit stack list (item, count) is traced at restore start and end.
- Blueprint Unit inventory: 120 slots, +1,000,000% stack size (was +10,000%).
- `bpu_trace.log` is truncated at start when it is over 2 MB.
- F and Esc no longer write trace lines while the window is closed.
- Known limits: single-player oriented; the split step edits the inventory locally (not a game command), so co-op may desync after it; belts and machine contents are not restored.

### Fixed
- A restore whose verify timed out while the game was still applying commands ended with a short container and no retry. Now the verify waits as long as the restored items keep changing.
- Shortages inside a full container were dropped without a note. Every shortage now has a note.
- Removed the inventory-trace diagnostics hooks.
- Restore verify: a container drained by adjacent belts (all TRANSFERs acked, total not up) counts as confirmed; no false stall.
- Floor check: Dock_2 floor is 30x30 (no rotation swap); a footprint across two touching floors validates against their union.

### Known limits (Station Build)
- Tested in game (2026-11-08): research read, replace of a Shipyard side by a Station 1x1, the apply. Not tested: blocks of other classes and rotations, machines standing on a removed block (the game refunds as for the factory).
- Machines of a placed block show up in the game 20-30 s later (the existing overlay covers the wait).


## [0.1.0] - 2026-11-07

Requires **MSCore 0.7.5 or newer** (install or update with MSCoreManager).

### Added
- Blueprint Unit station block, cloned from the Command Module, researched under Computation Science.
- Blueprint Unit window (press F on the console): import a factory blueprint JSON from the ms-factory-blueprint site.
- Modification Cost list, shown before you build. Scroll bars are always visible on the Cost and Notes lists.
- Notes panel on the right, scrollable. Duplicate notes are folded, at most 8 lines shown.
- Build: places the factory on your station, keeps identical machines, changes only recipes.
- Build sends all removals, then all placements, back to back (MSCore 0.7.5 refund/charge redirect). Refunds land in the unit inventory. The charge takes unit items first.
- Machines outside the modeled floors are placed anyway, with a note ("N placed outside the modeled floors").
- Esc closes the Blueprint Unit window and the game pause menu with it.
- Blueprint Unit inventory: 120 slots, +10,000% stack size.

### Experimental (off by default)
- Container contents restore after Build. It runs only if `Mods\BlueprintUnit\restore_on.txt` exists. Leave it off for normal use.
