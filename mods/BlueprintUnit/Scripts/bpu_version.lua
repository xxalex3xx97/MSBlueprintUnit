-- bpu_version: mod version and the minimum MSCore / Lua API this build needs.
-- dock names (Blocks[].Name) need MSCore 0.8.3 (rename_dock, block mids); older MSCore: the names are skipped with a message, the rest works.
-- station_build_min_mscore: Station Build (Chk_StationBuild) needs the MSCore 0.8.0 natives; min_mscore stays 0.7.6 for the rest.
return { version = "0.4.0", min_mscore = "0.7.6", min_lua_api = 3, station_build_min_mscore = "0.8.0" }
