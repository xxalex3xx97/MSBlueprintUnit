# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - 2026-11-07

Requires **MSCore 0.7.5 or newer** (install or update with MSCoreManager).

### Added
- Blueprint Unit station block, cloned from the Command Module, researched under Computation Science.
- Blueprint Unit window (press F on the console): import a factory blueprint JSON from the ms-factory-blueprint site.
- Modification Cost list, shown before you build. Scroll bars are always visible on the Cost and Notes lists.
- Notes panel on the right, scrollable. Duplicate notes are folded, at most 8 lines shown.
- Build: places the factory on your station, keeps identical machines, changes only recipes.
- Build sends all removals, then all placements, back to back (MSCore 0.7.5 refund/charge redirect). Refunds land in the unit inventory. The charge takes unit items first.
- Machines outside the modeled floors are skipped with a note instead of refusing the import.
- Esc closes the Blueprint Unit window and the game pause menu with it.
- Blueprint Unit inventory: 120 slots, +10,000% stack size.

### Experimental (off by default)
- Container contents restore after Build. It runs only if `Mods\BlueprintUnit\restore_on.txt` exists. Leave it off for normal use.
