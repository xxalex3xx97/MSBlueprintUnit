import bpy, bmesh, sys, math
from mathutils import Vector
# blender -b -P mk_table.py -- out.fbx [preview_prefix]
# v3: vanilla-Designer silhouette language (drum + bands, deck, raised disc plateau, 4 bevelled orange wedge frames with
# tilted Screens panels, 4 small bevelled housings on the disc). Own geometry. cm in, Blender metres out.
a = sys.argv[sys.argv.index('--') + 1:]
out = a[0]
s = 0.01  # cm -> Blender m
bpy.ops.wm.read_factory_settings(use_empty=True)
SEG = 48
# 'Holotable' = disc slot, same name as the vanilla Holotable mesh slot (-> /Game/Materials/M_Holotable). Only the flat disc uses it.
NAMES = ('Orange1', 'White1', 'Grey1', 'Black1', 'Screen1', 'Ring1', 'Holotable')
M = {n: bpy.data.materials.new(n) for n in NAMES}
parts, hulls = [], []
ANG = (0, 90, 180, 270)
# UV rule: 1 uv unit = 1 m on paint slots, Screen1 panels 0..1 (16:9, undistorted), Holotable disc 0..1 across its diameter
# (vanilla planar centred mapping).

def edit_uv(o, fn):
    bm = bmesh.new(); bm.from_mesh(o.data)
    uv = bm.loops.layers.uv.verify()
    for f in bm.faces:
        for l in f.loops:
            l[uv].uv = fn(f, l)
    bm.to_mesh(o.data); bm.free()

def fin(mat, o):
    for m in (mat if isinstance(mat, (list, tuple)) else [mat]):
        o.data.materials.append(M[m])
    parts.append(o)
    return o

def mesh_obj(name, bm):
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); bpy.context.collection.objects.link(o)
    bpy.context.view_layer.objects.active = o
    for x in bpy.context.selected_objects: x.select_set(False)
    o.select_set(True)
    return o

def lathe(prof, mat):
    # revolve closed (r, z) cm profile; flat faces planar-UV (world metres), others u = turns, v = profile arc length
    n = SEG
    bm = bmesh.new()
    cum = [0.0]
    for i in range(1, len(prof) + 1):
        p, q = prof[i - 1], prof[i % len(prof)]
        cum.append(cum[-1] + math.hypot(q[0] - p[0], q[1] - p[1]) * s)
    K = max(1, round(2 * math.pi * max(r for r, z in prof) * s))
    R = []
    for r, z in prof:
        if r == 0: R.append([bm.verts.new((0, 0, z * s))] * n)
        else: R.append([bm.verts.new((r * s * math.cos(2 * math.pi * j / n), r * s * math.sin(2 * math.pi * j / n), z * s)) for j in range(n)])
    fl = []
    for i in range(len(prof)):
        i2 = (i + 1) % len(prof)
        if prof[i][0] == 0 and prof[i2][0] == 0: continue
        flat = abs(prof[i][1] - prof[i2][1]) < 1e-6
        for j in range(n):
            j2 = (j + 1) % n
            cs = [(R[i][j], i, j), (R[i][j2], i, j + 1), (R[i2][j2], i2, j + 1), (R[i2][j], i2, j)]
            vs, us = [], []
            for v, pi, jj in cs:
                if vs and vs[-1] is v: continue
                if not vs or True: vs.append(v)
                if flat: us.append((v.co.x, v.co.y))
                else: us.append((jj / n * K, cum[pi]))
            if len(vs) > 1 and vs[0] is vs[-1]: vs.pop(); us.pop()
            if len(vs) < 3: continue
            f = bm.faces.new(vs); fl.append((f, us))
    uvl = bm.loops.layers.uv.verify()
    for f, us in fl:
        for l, u in zip(f.loops, us): l[uvl].uv = u
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    o = mesh_obj('lathe', bm)
    return fin(mat, o)

def band(rin, rout, z0, z1, mat, c=0.8):
    return lathe([(rin, z0), (rout - c, z0), (rout, z0 + c), (rout, z1 - c), (rout - c, z1), (rin, z1)], mat)

def bevel(o, w, seg=2, ang=28):
    bpy.context.view_layer.objects.active = o
    for x in bpy.context.selected_objects: x.select_set(False)
    o.select_set(True)
    bpy.ops.object.modifier_add(type='BEVEL')
    m = o.modifiers[-1]
    m.width = w * s; m.segments = seg; m.limit_method = 'ANGLE'; m.angle_limit = math.radians(ang)
    bpy.ops.object.modifier_apply(modifier=m.name)

def box_uv(o):
    def fn(f, l):
        n = f.normal; p = l.vert.co
        ax = max(range(3), key=lambda i: abs(n[i]))
        return {0: (p.y, p.z), 1: (p.x, p.z), 2: (p.x, p.y)}[ax]
    edit_uv(o, fn)

def W(t, r, ang):
    # local (tangent, radial) cm -> world cm; tangent = counter-clockwise
    c, sn = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    return (r * c - t * sn, r * sn + t * c)

def prism(plan, zb, ztop, ang):
    # plan (t, r) polygon extruded between zb and ztop(r); returns bmesh with world-metre verts and the point list (hull)
    bm = bmesh.new()
    pts = []
    top = []; bot = []
    for t, r in plan:
        x, y = W(t, r, ang)
        top.append(bm.verts.new((x * s, y * s, ztop(r) * s))); bot.append(bm.verts.new((x * s, y * s, zb * s)))
        pts += [(x * s, y * s, ztop(r) * s), (x * s, y * s, zb * s)]
    n = len(plan)
    bm.faces.new(top); bm.faces.new(bot[::-1])
    for i in range(n):
        bm.faces.new((bot[i], bot[(i + 1) % n], top[(i + 1) % n], top[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm, pts

def hull_from(pts):
    bm = bmesh.new()
    for p in pts: bm.verts.new(p)
    bmesh.ops.convex_hull(bm, input=list(bm.verts))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    return bm

def housing(plan, zb, ztop, ang, w, mat='Orange1'):
    bm, pts = prism(plan, zb, ztop, ang)
    o = mesh_obj('hous', bm)
    bevel(o, w); box_uv(o)
    hulls.append(pts)
    return fin(mat, o)

# ---- body: drum (bevelled), deck, inner step, raised disc plateau with rim wall
lathe([(0, 0), (151, 0), (154, 3), (154, 82), (150, 86), (132, 86), (129, 90), (101, 90), (101, 93), (99, 95), (97, 95), (97, 94), (0, 94)], 'Grey1')
# drum bands (proud of the drum, chamfered): black bands, white trims
band(153, 155.4, 23, 27, 'Black1')
band(153, 155.0, 38.2, 40.2, 'White1', 0.6)
band(153, 155.4, 46, 48.5, 'Black1')
band(153, 155.4, 61, 65, 'Black1')
band(147, 155.0, 78.5, 80.2, 'White1', 0.6)
# thin blue accent rings (M_Hologram): outer deck + inner step; raised 1.2 cm, embedded 0.4
lathe([(139, 85.6), (139, 86.6), (139.6, 87.2), (141.4, 87.2), (142, 86.6), (142, 85.6)], 'Ring1')
lathe([(117, 89.6), (117, 90.6), (117.6, 91.2), (119.4, 91.2), (120, 90.6), (120, 89.6)], 'Ring1')
lathe([(103.2, 89.6), (103.2, 90.6), (103.8, 91.2), (105, 91.2), (105.6, 90.6), (105.6, 89.6)], 'Ring1')

# ---- 4 large orange wedge frames, each carrying a tilted Screens panel (0..1 uv, 16:9)
FR_IN, FR_OUT = 112, 157.5
fz = lambda r: 100 - (r - FR_IN) * 12 / (FR_OUT - FR_IN)
FRAME = [(-50, FR_IN), (50, FR_IN), (62, 143), (32, 154.5), (-32, 154.5), (-62, 143)]
SH, SR0, SR1 = 32, 116.0, 151.2   # panel half width, radial start/end: 64 x ~36 (16:9 along the slope)
for ang in ANG:
    housing(FRAME, 72, fz, ang, 3.4)
    bm = bmesh.new()
    uvl = bm.loops.layers.uv.verify()
    pts = []
    for (t, r, u, v) in ((-SH, SR1, 0, 0), (SH, SR1, 1, 0), (SH, SR0, 1, 1), (-SH, SR0, 0, 1)):
        x, y = W(t, r, ang)
        pts.append((bm.verts.new((x * s, y * s, (fz(r) + 0.35) * s)), (u, v)))
    f = bm.faces.new([p for p, _ in pts])
    if f.normal.dot(Vector((math.cos(math.radians(ang)), math.sin(math.radians(ang)), 1))) < 0: f.normal_flip()
    f.normal_update()
    for l in f.loops: l[uvl].uv = [u for p, u in pts if p == l.vert][0]
    fin('Screen1', mesh_obj('screen', bm))

# ---- 4 small orange housings on the disc (blocky, sloped outer edge)
SMALL = [(-30, 80), (30, 80), (32, 98), (20, 108.5), (-20, 108.5), (-32, 98)]
sz = lambda r: 112 - (r - 80) * 10 / 28.5
for ang in ANG:
    housing(SMALL, 86, sz, ang, 3.0)

# ---- disc: ONE flat +Z-facing polygon at z=95, slot Holotable, vanilla planar centred UV (0..1 across the diameter, rotated 56.2 deg)
bm = bmesh.new()
f = bm.faces.new([bm.verts.new((97 * s * math.cos(2 * math.pi * j / SEG), 97 * s * math.sin(2 * math.pi * j / SEG), 95 * s)) for j in range(SEG)])
if f.normal.z < 0: f.normal_flip()
uvl = bm.loops.layers.uv.verify()
for l in f.loops:
    x, y = l.vert.co.x / s, l.vert.co.y / s  # cm
    l[uvl].uv = (0.00289 * x + 0.00432 * y + 0.5, -0.00432 * x + 0.00289 * y + 0.5)
fin('Holotable', mesh_obj('disc', bm))

bpy.ops.object.select_all(action='DESELECT')
for p in parts:
    p.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
o = bpy.context.active_object
o.name = 'SM2_BPUnitTbl'; o.data.name = 'SM2_BPUnitTbl'
bpy.ops.object.shade_flat()

# ---- collision: UCX_ convex hulls (never rendered by UE, collision only)
hl = []
def add_hull(bm):
    h = mesh_obj('UCX_SM2_BPUnitTbl_%02d' % (len(hl) + 1), bm); hl.append(h); h.data.name = h.name; return h
def ring_pts(r, z, n=24):
    return [(r * s * math.cos(2 * math.pi * i / n), r * s * math.sin(2 * math.pi * i / n), z * s) for i in range(n)]
add_hull(hull_from(ring_pts(154, 0) + ring_pts(154, 86)))                 # drum + deck
add_hull(hull_from(ring_pts(101, 86) + ring_pts(101, 95)))                # disc plateau
for p in hulls: add_hull(hull_from(p))                                     # 4 frames + 4 small housings
for h in hl:
    h.data.materials.clear()
bpy.ops.object.select_all(action='DESELECT')
o.select_set(True)
for h in hl: h.select_set(True)
bpy.context.view_layer.objects.active = o
bpy.ops.export_scene.fbx(filepath=out, use_selection=True, object_types={'MESH'},
    apply_scale_options='FBX_SCALE_UNITS', axis_forward='-Y', axis_up='Z',
    add_leaf_bones=False, bake_anim=False, mesh_smooth_type='FACE')
print('EXPORTED', out, tuple(o.dimensions), [m.name for m in o.data.materials], 'hulls', [(h.name, len(h.data.vertices)) for h in hl])

if len(a) > 1:  # optional previews: a[1] = path prefix
    pre = a[1]
    sc = bpy.context.scene
    for h in hl: h.hide_render = True
    cols = {'Orange1': (1, .35, .02), 'White1': (.85, .85, .85), 'Grey1': (.25, .27, .3), 'Black1': (.03, .03, .04), 'Ring1': (.1, .4, 1), 'Screen1': (.1, .8, .9), 'Holotable': (.02, .08, .25)}
    for n_, m in M.items():
        m.diffuse_color = cols[n_] + (1,)
    sc.render.engine = 'BLENDER_WORKBENCH'
    sc.display.shading.color_type = 'MATERIAL'
    sc.display.shading.light = 'STUDIO'
    sc.render.resolution_x = 900; sc.render.resolution_y = 600
    cam = bpy.data.objects.new('c', bpy.data.cameras.new('c')); bpy.context.collection.objects.link(cam)
    sc.camera = cam
    def shot(name, loc, tgt, ortho=0, lens=50):
        cam.location = loc
        cam.data.type = 'ORTHO' if ortho else 'PERSP'
        cam.data.ortho_scale = ortho or 6; cam.data.lens = lens
        cam.rotation_euler = (Vector(tgt) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        sc.render.filepath = pre + '_' + name + '.png'
        bpy.ops.render.render(write_still=True)
    def shots(tag):
        shot(tag + 'iso', (4.6, -4.6, 3.4), (0, 0, .5))
        shot(tag + 'top', (0, 0, 8), (0, 0, 0), ortho=3.6)
        shot(tag + 'side', (0, -8, .55), (0, 0, .55), ortho=3.8)
        shot(tag + 'close', (2.9, -1.6, 1.9), (1.3, 0, .95), lens=35)
        shot(tag + 'disc', (0, 0, 8), (0, 0, .95), ortho=2.2)
    shots('')
    # checker on every slot (disc one shows the centred planar uv; others 1 m tiles)
    img = bpy.data.images.new('chk', 1024, 1024)
    img.generated_type = 'COLOR_GRID'
    for m in M.values():
        m.use_nodes = True
        t = m.node_tree.nodes.new('ShaderNodeTexImage'); t.image = img
        m.node_tree.nodes.active = t
    sc.display.shading.color_type = 'TEXTURE'
    shots('chk_')
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.export_layout(filepath=pre + '_uv.png', size=(1024, 1024), opacity=0.5)
    bpy.ops.object.mode_set(mode='OBJECT')
    for h in hl: h.hide_render = False; h.display_type = 'WIRE'
    sc.display.shading.color_type = 'MATERIAL'
    shot('hulls', (4.6, -4.6, 3.4), (0, 0, .5))
