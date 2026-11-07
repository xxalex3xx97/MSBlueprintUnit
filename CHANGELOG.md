# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Reads station blocks/machines through MSCore 0.7.2 native read_station (no more Lua struct reads, which crashed UE4SS). Requires MSCore 0.7.2.
- Inventory slots (unit and player) read natively via MSCore 0.7.3 read_inventory. Requires MSCore 0.7.3.

### Fixed
- Build said "not enough items" although the unit and player inventories held the items (slot structs read in Lua returned nothing). Fixed by the native inventory read.

First release: see 0.1.0 below.

## [0.1.0] - 2026-11-07

### Added
- Blueprint Unit station block, cloned from the Command Module, researched under Computation Science.
- Blueprint Unit window (press F on the console): import a factory blueprint JSON from the ms-factory-blueprint site.
- Modification Cost list, shown before you build.
- Build: places the factory on your station, keeps identical machines, changes only recipes, and refunds into the unit inventory.
- Blueprint Unit inventory: 120 slots, +10,000% stack size.
- Install through MSCoreManager (requires MSCore 0.7.2 or newer).
