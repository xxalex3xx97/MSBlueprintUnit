import bpy, sys, itertools
from mathutils import Vector
a = sys.argv[sys.argv.index('--') + 1:]
out = a[0]
s = 0.01  # cm -> Blender m
bpy.ops.wm.read_factory_settings(use_empty=True)
mat = bpy.data.materials.new('Holo1')
parts = []

def bar(p, q, t):
    p, q = Vector(p), Vector(q)
    bpy.ops.mesh.primitive_cube_add(size=1, location=((p + q) / 2 * s))
    o = bpy.context.active_object
    o.scale = (t * s, t * s, (q - p).length * s)
    o.rotation_euler = (q - p).to_track_quat('Z', 'Y').to_euler()
    bpy.ops.object.transform_apply(location=False, scale=True, rotation=True)
    parts.append(o)

def corners(h):
    return [(x * h, y * h, z * h) for x, y, z in itertools.product((-1, 1), repeat=3)]

def cube(h, t):
    c = corners(h)
    for p, q in itertools.combinations(c, 2):
        if sum(abs(u - v) > 0 for u, v in zip(p, q)) == 1:
            bar(p, q, t)

cube(35, 2.0)   # outer frame 70 cm
cube(14, 1.5)   # inner frame 28 cm
for p, q in zip(corners(35), corners(14)):
    bar(p, q, 1.0)  # connectors
for p in corners(35):
    bpy.ops.mesh.primitive_cube_add(size=1, location=tuple(v * s for v in p))
    o = bpy.context.active_object; o.scale = (4 * s,) * 3
    bpy.ops.object.transform_apply(location=False, scale=True); parts.append(o)

bpy.ops.object.select_all(action='DESELECT')
for p in parts:
    p.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
o = bpy.context.active_object
o.name = 'SM_BPUnitBlueprintHolo_01'
assert len(o.name) == 25
o.data.materials.append(mat)
bpy.ops.object.shade_flat()
bpy.ops.object.select_all(action='DESELECT')
o.select_set(True)
bpy.context.view_layer.objects.active = o
bpy.ops.export_scene.fbx(filepath=out, use_selection=True, object_types={'MESH'},
    apply_scale_options='FBX_SCALE_UNITS', axis_forward='-Y', axis_up='Z',
    add_leaf_bones=False, bake_anim=False, mesh_smooth_type='FACE')
print('EXPORTED', out, tuple(o.dimensions))
if len(a) > 1:
    mat.diffuse_color = (.1, .4, 1, 1)
    bpy.context.scene.render.engine = 'BLENDER_WORKBENCH'
    bpy.context.scene.render.resolution_x = 600; bpy.context.scene.render.resolution_y = 600
    cam = bpy.data.objects.new('c', bpy.data.cameras.new('c')); bpy.context.collection.objects.link(cam)
    cam.location = (1.6, -1.6, 1.1)
    cam.rotation_euler = (-cam.location).to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam
    bpy.context.scene.render.filepath = a[1]
    bpy.ops.render.render(write_still=True)
