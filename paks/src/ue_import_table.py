import os, traceback, unreal
ART = os.path.join(os.path.dirname(os.path.abspath(__file__)), "art") + os.sep  # ponytail: relies on __file__ under UE python exec
LOG = os.path.join(os.environ.get("TEMP", "."), "bpunit_import.log")
# stand-ins at the exact game paths (never packed): name -> (dir, class)
MI, MAT = "mic", "mat"
STAND = {
    "MI_PaintedMetal_Grey": ("/Game/Materials/Instances", MI), "MI_PaintedMetal_White": ("/Game/Materials/Instances", MI),
    "MI_PaintedMetal_Orange": ("/Game/Materials/Instances", MI), "MI_PaintedMetal_Black": ("/Game/Materials/Instances", MI),
    "MI_Screens_01": ("/Game/Art/MaterialLibrary", MI),
    "M_Holotable": ("/Game/Materials", MAT), "M_NewStickers": ("/Game/Materials", MAT), "M_Hologram": ("/Game/Materials", MAT),
}
# meshes: name -> (dest dir, {slot name: material asset path})
MESHES = {
    "SM2_BPUnitTbl": ("/Game/Meshes/Machines", {
        "Orange1": "/Game/Materials/Instances/MI_PaintedMetal_Orange", "White1": "/Game/Materials/Instances/MI_PaintedMetal_White",
        "Grey1": "/Game/Materials/Instances/MI_PaintedMetal_Grey", "Black1": "/Game/Materials/Instances/MI_PaintedMetal_Black",
        "Screen1": "/Game/Art/MaterialLibrary/MI_Screens_01", "Ring1": "/Game/Materials/M_Hologram",
        "Holotable": "/Game/Materials/M_Holotable"}),
    "SM_BPUnitBlueprintHolo_01": ("/Game/Meshes/Effects", {"Holo1": "/Game/Materials/M_Hologram"}),
    # same-length (18) replacement for SM2_LargeContainer in the cloned actor: tiny, 6 slots, no collision
    "SM2_BPUnitHidden00": ("/Game/Meshes/Machines", {"Hid%d" % i: "/Game/Materials/Instances/MI_PaintedMetal_Black" for i in range(6)}),
}
assert len("SM2_BPUnitHidden00") == len("SM2_LargeContainer") == 18
L = []
def log(m):
    L.append(str(m)); unreal.log("[bpunit] " + str(m))
def sp(o, k, v):
    try: o.set_editor_property(k, v)
    except Exception as e: log("  set %s failed: %r" % (k, e))
def main():
    global eal, at
    # Interchange ignores FbxImportUI options and skipped our UCX_ hulls: force the legacy FBX importer
    unreal.SystemLibrary.execute_console_command(None, "Interchange.FeatureFlags.Import.FBX 0")
    eal = unreal.EditorAssetLibrary
    at = unreal.AssetToolsHelpers.get_asset_tools()
    for n, (d, k) in STAND.items():
        p = d + "/" + n
        if eal.does_asset_exist(p): continue
        if k == MAT:
            at.create_asset(n, d, unreal.Material, unreal.MaterialFactoryNew())
        else:
            a = at.create_asset(n, d, unreal.MaterialInstanceConstant, unreal.MaterialInstanceConstantFactoryNew())
            a.set_editor_property("parent", eal.load_asset("/Game/Materials/MM_Interior"))
        eal.save_asset(p)
        log("stand-in " + p)
    for name, (dest, _) in MESHES.items():
        p = dest + "/" + name
        # ponytail: import_asset_tasks for a static mesh saves the package, then asserts in Slate (commandlet has no
        # SlateApplication). Import ONE mesh per run: return after it, rerun the script for the next, then post-process.
        if not eal.does_asset_exist(p):
            t = unreal.AssetImportTask()
            sp(t, "filename", ART + name + ".fbx"); sp(t, "destination_path", dest); sp(t, "destination_name", name)
            sp(t, "automated", True); sp(t, "save", True); sp(t, "replace_existing", True)
            o = unreal.FbxImportUI()
            sp(o, "import_mesh", True); sp(o, "import_textures", False); sp(o, "import_materials", False)
            sp(o, "import_as_skeletal", False)
            d = o.static_mesh_import_data
            sp(d, "build_nanite", False); sp(d, "combine_meshes", True); sp(d, "convert_scene_unit", True)
            sp(d, "generate_lightmap_u_vs", False); sp(d, "auto_generate_collision", name == "SM_BPUnitBlueprintHolo_01")  # table ships UCX_ hulls, hidden none
            sp(t, "options", o)
            at.import_asset_tasks([t])
            log("imported %s (crash expected next; rerun to continue)" % p)
            return
    for name, (dest, slotmap) in MESHES.items():
        p = dest + "/" + name
        sm = eal.load_asset(p)
        if sm is None: raise RuntimeError("no asset " + p)
        for i, st in enumerate(sm.static_materials):
            sn = str(st.material_slot_name)
            if sn in slotmap: sm.set_material(i, eal.load_asset(slotmap[sn]))
            else: log("  UNMAPPED slot " + sn)
        if name == "SM2_BPUnitHidden00":
            unreal.EditorStaticMeshLibrary.remove_collisions(sm)
            sp(sm.get_editor_property("body_setup"), "collision_trace_flag", unreal.CollisionTraceFlag.CTF_USE_SIMPLE_AS_COMPLEX)
        eal.save_loaded_asset(sm)
        e = sm.get_bounds().box_extent; org = sm.get_bounds().origin
        log("%s slots=%s origin=(%s,%s,%s) extent=(%s,%s,%s)" % (p, [str(s.material_slot_name) for s in sm.static_materials], org.x, org.y, org.z, e.x, e.y, e.z))
        try:
            b = sm.get_editor_property("body_setup"); g0 = b.get_editor_property("agg_geom")
            log("  SIMPLECOLL total=%d" % sum(len(g0.get_editor_property(k)) for k in ("convex_elems", "box_elems", "sphere_elems", "sphyl_elems", "tapered_capsule_elems")))
            g = sm.get_editor_property("body_setup").get_editor_property("agg_geom")
            cv = g.get_editor_property("convex_elems")
            log("  collision: %d convex elems, box=%d, trace_flag=%s, EditorStaticMeshLibrary convex count=%s" % (len(cv), len(g.get_editor_property("box_elems")), sm.get_editor_property("body_setup").get_editor_property("collision_trace_flag"), unreal.EditorStaticMeshLibrary.get_convex_collision_count(sm)))
        except Exception as ex: log("  collision read failed %r" % ex)
        log("  mats=" + str([s.material_interface.get_path_name() for s in sm.static_materials]))
    log("POSTDONE")
try: main()
except Exception as e:
    log("FAILED: %r" % e); log(traceback.format_exc())
finally:
    open(LOG, "w", encoding="utf-8").write("\n".join(L) + "\n")
