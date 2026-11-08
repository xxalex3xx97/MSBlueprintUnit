# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Restore sorts the unit inventory first, then splits the exact missing amount into a free unit slot and moves it with one TRANSFER (needs the MSCore 0.7.6 split native; older MSCore keeps the whole-stack rounding). The split step edits the inventory locally (not a game command; in co-op it may desync until the next refresh).
- Container contents restore is on by default. An optional `Chk_Restore` checkbox turns it off (unchecked = off). `Mods\BlueprintUnit\restore_off.txt` forces it off; `restore_probe.txt` runs the 5-item probe. `restore_on.txt` is no longer needed.
- Restore moves whole unit stacks only (one TRANSFER per stack, no cursor, no put-back). Amounts are rounded to whole stacks: a stack is moved when the missing amount is at least half of it (the container can get up to half a stack more than the blueprint count), and a smaller remainder is left out with a note ("left out (under half a unit stack)").
- A container's stack room is respected: a partial move leaves the rest in the unit, and a full container is noted ("container id N full").
- A refused send is retried on the next tick (up to 5 times), then skipped and counted in the note ("N command(s) skipped (refused)"). The restore never aborts for it.
- Restore sends up to 1000 commands per tick. It stops only when nothing changes in the restored items for 8 s after the last send (no fixed wait).
- Progress line while building and restoring: "restoring [#####-----] 50%  (1,234 of 2,468 commands)" and "sending commands: n of m (x%)".
- Build button: while a build or restore runs it reads **Abort** and cancels the run. Closing the window also cancels it.
- Notes panel hides the "skipped (block-built ...)" and "ConfigHex ignored for paired underground ..." lines. They stay in `bpu_trace.log`.
- Notes: "plan reduced: unit has X of Y for Item (short Z)" when the unit lacks an item; "items on belts and in machines are not restored" line after restore.
- The unit stack list (item, count) is traced at restore start and end.

### Fixed
- A restore whose verify timed out while the game was still applying commands ended with a short container and no retry. Now the verify waits as long as the restored items keep changing.
- Shortages inside a full container were dropped without a note. Every shortage now has a note.
- Diagnostics hooks on the inventory command (`AddInventoryInteraction`) are no longer registered in the release path.
- Restore verify: a container drained by adjacent belts (all TRANSFERs acked, total not up) counts as confirmed; no false stall.
- Floor check: Dock_2 floor is 30x30 (no rotation swap); a footprint across two touching floors validates against their union.

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
